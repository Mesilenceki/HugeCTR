/*
 * Copyright (c) 2022, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#include <cub/cub.cuh>

#include "../common.hpp"
#include "../view.hpp"
#include "HugeCTR/include/utils.cuh"
#include "HugeCTR/include/utils.hpp"
#include "dp_index_calculation.hpp"
#include "index_calculation.hpp"
#include "mp_index_calculation.hpp"

namespace embedding {

namespace {

struct BucketInfo {
  uint32_t start;
  uint32_t end;
  int shard_id;
  int num_shards;
};

template <typename key_t, typename offset_t>
struct KeySelectorGPU {
  const key_t *__restrict__ keys_ptr;
  const offset_t *__restrict__ bucket_range_ptr;
  const int *__restrict__ lookup_ids_ptr;
  int num_lookup_before_filter;
  int num_lookup_after_filter;
  int gpu_id;
  int num_gpus;
  int batch_size_per_gpu;
  const int *shard_ids_ptr_;
  const int *num_shards_ptr_;

  KeySelectorGPU(const Tensor &keys, const Tensor &bucket_range, const MPKeySelector &key_selector,
                 int batch_size)
      : keys_ptr(keys.get<key_t>()),
        bucket_range_ptr(bucket_range.get<offset_t>()),
        lookup_ids_ptr(key_selector.lookup_ids.get<int>()),
        num_lookup_before_filter(key_selector.num_lookup_before_filter),
        num_lookup_after_filter(key_selector.num_lookup_after_filter),
        gpu_id(0),
        num_gpus(1),
        batch_size_per_gpu(batch_size),
        shard_ids_ptr_(key_selector.shard_ids.get<int>()),
        num_shards_ptr_(key_selector.num_shards.get<int>()) {}

  KeySelectorGPU(const Tensor &keys, const Tensor &bucket_range, const DPKeySelector &key_selector,
                 int batch_size)
      : keys_ptr(keys.get<key_t>()),
        bucket_range_ptr(bucket_range.get<offset_t>()),
        lookup_ids_ptr(key_selector.lookup_ids.get<int>()),
        num_lookup_before_filter(key_selector.num_lookup_before_filter),
        num_lookup_after_filter(key_selector.num_lookup_after_filter),
        gpu_id(key_selector.gpu_id),
        num_gpus(key_selector.num_gpus),
        batch_size_per_gpu(batch_size / key_selector.num_gpus),
        shard_ids_ptr_(nullptr),
        num_shards_ptr_(nullptr) {}

  DEVICE_INLINE int cal_bucket_idx(const int &i) const {
    int lookup_id = (lookup_ids_ptr == nullptr) ? i / batch_size_per_gpu
                                                : lookup_ids_ptr[i / batch_size_per_gpu];
    int idx = batch_size_per_gpu * num_lookup_before_filter * num_gpus;
    if (i < batch_size_per_gpu * num_lookup_before_filter * num_gpus) {
      idx = lookup_id * batch_size_per_gpu * num_gpus + gpu_id * batch_size_per_gpu +
            (i % batch_size_per_gpu);
    }
    return idx;
  }

  __device__ BucketInfo idx_to_selected_bucket(const int &i) const {
    offset_t start = bucket_range_ptr[cal_bucket_idx(i)];
    offset_t end = bucket_range_ptr[cal_bucket_idx(i) + 1];
    int shard_id = (shard_ids_ptr_ == nullptr) ? 0 : shard_ids_ptr_[i / batch_size_per_gpu];
    int num_shards = (num_shards_ptr_ == nullptr) ? 1 : num_shards_ptr_[i / batch_size_per_gpu];
    return {static_cast<uint32_t>(start), static_cast<uint32_t>(end), shard_id, num_shards};
  }
};

// Cautions: Dont use pass KeySelector by reference
template <typename key_t, typename offset_t>
__global__ void mask_and_count_keys_in_bucket_kernel(KeySelectorGPU<key_t, offset_t> key_selector,
                                                     const key_t *__restrict__ keys,
                                                     uint32_t *bucket_range_after_filter,
                                                     char *flag, int num) {
  int batch_size = key_selector.batch_size_per_gpu;
  CUDA_1D_KERNEL_LOOP(i, num) {
    if (i >= batch_size * key_selector.num_lookup_after_filter) {
      bucket_range_after_filter[1 + i] = 0;
      continue;
    }

    BucketInfo bucket_info = key_selector.idx_to_selected_bucket(i);
    uint32_t start_before_filter = bucket_info.start;
    uint32_t end_before_filter = bucket_info.end;
    int shard_id = bucket_info.shard_id;
    int num_shards = bucket_info.num_shards;

    uint32_t cnt_selected = 0;
    for (uint32_t l = 0; l < (end_before_filter - start_before_filter); ++l) {
      key_t k = keys[l + start_before_filter];
      if (k % num_shards == shard_id) {
        flag[l + start_before_filter] = 1;
        cnt_selected += 1;
      }
    }
    bucket_range_after_filter[1 + i] = cnt_selected;
    if (i == 0) {
      bucket_range_after_filter[0] = 0;
    }
  }
}

}  // namespace

void IndexCalculationTempStorage::init(const std::shared_ptr<CoreResourceManager> &core,
                                       int max_num_keys_before_filter,
                                       int max_num_keys_after_filter, int batch_size_before_filter,
                                       int batch_size_after_filter, int num_lookup) {
  HugeCTR::CudaDeviceContext ctx(core->get_device_id());
  Device device{DeviceType::GPU, core->get_device_id()};
  auto buffer_ptr = GetBuffer(core);

  this->flag = buffer_ptr->reserve({batch_size_before_filter * max_num_keys_before_filter}, device,
                                   TensorScalarType::Char);
  {
    size_t temp_bytes = 0;
    cub::DeviceSelect::Flagged(nullptr, temp_bytes, (uint64_t *)nullptr, (char *)nullptr,
                               (uint64_t *)nullptr, (size_t *)nullptr,
                               batch_size_before_filter * max_num_keys_before_filter);
    this->temp_select_storage = buffer_ptr->reserve({temp_bytes}, device, TensorScalarType::Void);
  }
  {
    size_t temp_bytes = 0;
    cub::DeviceScan::InclusiveSum(nullptr, temp_bytes, (uint64_t *)nullptr, (uint32_t *)nullptr,
                                  batch_size_after_filter * num_lookup + 1);
    this->temp_scan_storage = buffer_ptr->reserve({temp_bytes}, device, TensorScalarType::Void);
  }
  buffer_ptr->allocate();
}

template <>
void IndexCalculation<MPKeySelector>::init(std::shared_ptr<CoreResourceManager> core,
                                           const MPKeySelector &key_selector, int batch_size) {
  this->core_ = core;
  this->key_selector_ = key_selector;
  this->temp_storage_.init(core, key_selector.max_num_keys_before_filter,
                           key_selector.max_num_keys_after_filter, batch_size, batch_size,
                           key_selector.num_lookup_after_filter);
}

template <>
void IndexCalculation<DPKeySelector>::init(std::shared_ptr<CoreResourceManager> core,
                                           const embedding::DPKeySelector &key_selector,
                                           int batch_size) {
  this->core_ = core;
  this->key_selector_ = key_selector;
  this->temp_storage_.init(
      core, key_selector.max_num_keys_before_filter, key_selector.max_num_keys_after_filter,
      batch_size, batch_size / key_selector.num_gpus, key_selector.num_lookup_after_filter);
}

template <typename KeySelector>
void IndexCalculation<KeySelector>::filter_sparse_input(const Tensor &keys,
                                                        const Tensor &bucket_range,
                                                        EmbeddingInput &result, int batch_size) {
  HugeCTR::CudaDeviceContext ctx(core_->get_device_id());
  auto stream = core_->get_local_gpu()->get_stream();

  HCTR_LIB_THROW(cudaMemsetAsync(result.keys.get(), 0, result.keys.nbytes(), stream));
  HCTR_LIB_THROW(
      cudaMemsetAsync(result.bucket_range.get(), 0, result.bucket_range.nbytes(), stream));
  HCTR_LIB_THROW(cudaMemsetAsync(temp_storage_.flag.get(), 0, temp_storage_.flag.nbytes(), stream));

  DISPATCH_INTEGRAL_FUNCTION(keys.dtype().type(), key_t, [&] {
    DISPATCH_INTEGRAL_FUNCTION(bucket_range.dtype().type(), offset_t, [&] {
      const key_t *keys_ptr = keys.get<key_t>();

      uint32_t *bucket_range_after_filter = result.bucket_range.get<uint32_t>();
      key_t *keys_after_filter = result.keys.get<key_t>();

      KeySelectorGPU<key_t, offset_t> key_selector_gpu{keys, bucket_range, key_selector_,
                                                       batch_size};

      mask_and_count_keys_in_bucket_kernel<<<144 * 8, 256, 0, stream>>>(
          key_selector_gpu, key_selector_gpu.keys_ptr, bucket_range_after_filter,
          temp_storage_.flag.get<char>(), result.bucket_range.get_num_elements() - 1);

      size_t temp_scan_storage_nbytes = temp_storage_.temp_scan_storage.nbytes();
      cub::DeviceScan::InclusiveSum(temp_storage_.temp_scan_storage.get(), temp_scan_storage_nbytes,
                                    bucket_range_after_filter, bucket_range_after_filter,
                                    result.bucket_range.get_num_elements(), stream);

      size_t temp_select_storage_nbytes = temp_storage_.temp_select_storage.nbytes();
      cub::DeviceSelect::Flagged(temp_storage_.temp_select_storage.get(),
                                 temp_select_storage_nbytes, keys_ptr,
                                 temp_storage_.flag.get<char>(), keys_after_filter,
                                 result.num_keys.get<size_t>(), keys.get_num_elements(), stream);
      HCTR_LIB_THROW(cudaStreamSynchronize(stream));
      result.h_num_keys = static_cast<size_t>(result.num_keys.get<size_t>()[0]);
    });
  });
}

template class IndexCalculation<MPKeySelector>;
template class IndexCalculation<DPKeySelector>;

void ReductionIndices::init(std::shared_ptr<CoreResourceManager> core, int local_hotness_sum,
                            int batch_size) {
  HugeCTR::CudaDeviceContext context(core->get_device_id());
  int max_num_key_for_reduction = local_hotness_sum * batch_size;

  auto buffer_ptr = GetBuffer(core);
  this->src_ids =
      buffer_ptr->reserve({max_num_key_for_reduction}, DeviceType::GPU, TensorScalarType::UInt32);
  this->dst_ids =
      buffer_ptr->reserve({max_num_key_for_reduction}, DeviceType::GPU, TensorScalarType::UInt32);
  this->table_ids =
      buffer_ptr->reserve({max_num_key_for_reduction}, DeviceType::GPU, TensorScalarType::Int32);
  this->ev_sizes =
      buffer_ptr->reserve({max_num_key_for_reduction}, DeviceType::GPU, TensorScalarType::Int32);
  this->num_key = buffer_ptr->reserve({1}, DeviceType::GPU, TensorScalarType::Size_t);
  buffer_ptr->allocate();
}

void PartitionedResult::init(std::shared_ptr<CoreResourceManager> core, int num_lookup,
                             int num_table, int local_hotness_sum, int batch_size,
                             DataType key_type) {
  HugeCTR::CudaDeviceContext context(core->get_device_id());

  auto buffer_ptr = GetBuffer(core);
  this->partitioned_keys =
      buffer_ptr->reserve({batch_size * local_hotness_sum}, DeviceType::GPU, key_type);
  this->partitioned_src_ids = buffer_ptr->reserve({batch_size * local_hotness_sum}, DeviceType::GPU,
                                                  TensorScalarType::UInt32);
  this->partitioned_bucket_range =
      buffer_ptr->reserve({num_lookup * batch_size + 1}, DeviceType::GPU, TensorScalarType::UInt32);
  this->partitioned_table_range =
      buffer_ptr->reserve({num_table + 1}, DeviceType::GPU, TensorScalarType::Int32);

  buffer_ptr->allocate();
}

void SortedResult::init(std::shared_ptr<CoreResourceManager> core, int local_hotness_sum,
                        int batch_size, DataType key_type) {
  HugeCTR::CudaDeviceContext ctx(core->get_device_id());

  auto buffer_ptr = GetBuffer(core);
  this->sorted_keys =
      buffer_ptr->reserve({batch_size * local_hotness_sum}, DeviceType::GPU, key_type);

  buffer_ptr->allocate();
}

namespace {

template <typename offset_t>
__global__ void subtract_left_kernel(const int *sorted_lookup_ids, const offset_t *bucket_range,
                                     int num_lookup, int batch_size, uint32_t *output) {
  CUDA_1D_KERNEL_LOOP(i, num_lookup * batch_size) {
    int lookup_id = sorted_lookup_ids[i / batch_size];
    int idx = lookup_id * batch_size + i % batch_size;
    output[1 + i] =
        static_cast<uint32_t>(bucket_range[idx + 1]) - static_cast<uint32_t>(bucket_range[idx]);
  }
  if (threadIdx.x + blockIdx.x * blockDim.x == 0) {
    output[0] = 0ul;
  }
}

template <typename key_t, typename offset_t>
__global__ void group_keys_by_lookup_id_kernel(const int *sorted_lookup_ids, const key_t *keys,
                                               const offset_t *bucket_range,
                                               const uint32_t *partitioned_bucket_range,
                                               int num_lookup, int batch_size,
                                               key_t *partitioned_keys) {
  CUDA_1D_KERNEL_LOOP(idx, num_lookup * batch_size) {
    int lookup_id = sorted_lookup_ids[idx / batch_size];
    uint32_t start = static_cast<uint32_t>(bucket_range[lookup_id * batch_size + idx % batch_size]);
    uint32_t end =
        static_cast<uint32_t>(bucket_range[lookup_id * batch_size + idx % batch_size + 1]);

    uint32_t partitioned_start = partitioned_bucket_range[idx];

    for (uint32_t i = start; i < end; ++i) {
      partitioned_keys[partitioned_start + i - start] = keys[i];
    }
  }
}

void group_keys_by_lookup_id(const Tensor &keys, const Tensor &bucket_range,
                             const Tensor &sorted_lookup_ids, int num_lookup, int batch_size,
                             Tensor &partitioned_keys, Tensor &partitioned_bucket_range,
                             LocalReduceIndexCalculationTempStorage &temp_storage,
                             cudaStream_t stream) {
  DISPATCH_INTEGRAL_FUNCTION(keys.dtype().type(), key_t, [&] {
    DISPATCH_INTEGRAL_FUNCTION(bucket_range.dtype().type(), offset_t, [&] {
      constexpr int grid_dim_x = 144 * 8;
      constexpr int block_dim_x = 32;

      subtract_left_kernel<<<grid_dim_x, block_dim_x, 0, stream>>>(
          sorted_lookup_ids.get<int>(), bucket_range.get<offset_t>(), num_lookup, batch_size,
          partitioned_bucket_range.get<uint32_t>());

      size_t temp_storage_nbytes = temp_storage.temp_scan_storage.nbytes();
      cub::DeviceScan::InclusiveSum(temp_storage.temp_scan_storage.get(), temp_storage_nbytes,
                                    partitioned_bucket_range.get<uint32_t>(),
                                    partitioned_bucket_range.get<uint32_t>(),
                                    num_lookup * batch_size + 1, stream);

      group_keys_by_lookup_id_kernel<<<grid_dim_x, block_dim_x, 0, stream>>>(
          sorted_lookup_ids.get<int>(), keys.get<key_t>(), bucket_range.get<offset_t>(),
          partitioned_bucket_range.get<uint32_t>(), num_lookup, batch_size,
          partitioned_keys.get<key_t>());
    });
  });
}

template <typename offset_t>
__global__ void replicate_bucket_range_kernel(const offset_t *bucket_range,
                                              const int *sorted_lookup_ids,
                                              const int *sorted_table_ids,
                                              const int *table_id_to_ev_size, int num_lookup,
                                              int batch_size, uint32_t *src_ids, int *table_ids,
                                              int *ev_sizes, size_t *num_key) {
  extern __shared__ uint32_t smem_buffer[];
  uint32_t *smem_bucket_range = smem_buffer;

  int32_t max_bucket_num = num_lookup * batch_size;
  for (int32_t i = blockIdx.x * blockDim.x, step = blockDim.x * gridDim.x; i < max_bucket_num;
       i += step) {
    int max_local_id = blockDim.x < max_bucket_num - blockIdx.x * blockDim.x
                           ? blockDim.x
                           : max_bucket_num - blockIdx.x * blockDim.x;
    {
      int32_t global_id = i + threadIdx.x;
      if (threadIdx.x < max_local_id) {
        uint32_t start = static_cast<uint32_t>(bucket_range[global_id]);
        uint32_t end = static_cast<uint32_t>(bucket_range[global_id + 1]);
        smem_bucket_range[threadIdx.x] = start;
        if (threadIdx.x == max_local_id - 1) smem_bucket_range[max_local_id] = end;
        if (global_id == max_bucket_num - 1) num_key[0] = end;
      }
    }
    __syncthreads();
    for (int local_index = smem_bucket_range[0] + threadIdx.x;
         local_index < smem_bucket_range[max_local_id]; local_index += blockDim.x) {
      int idx = binary_search_index_lower_bound(smem_bucket_range, max_local_id + 1,
                                                (uint32_t)local_index) +
                blockIdx.x * blockDim.x;
      int lookup_id = sorted_lookup_ids[idx / batch_size];
      uint32_t bucket_id = lookup_id * batch_size + idx % batch_size;
      int table_id = sorted_table_ids[idx / batch_size];
      table_ids[local_index] = table_id;
      ev_sizes[local_index] = table_id_to_ev_size[table_id];
      src_ids[local_index] = bucket_id;
    }
  }
}

void replicate_bucket_range(const Tensor &bucket_range, const Tensor &sorted_lookup_ids,
                            const Tensor &sorted_table_ids, const Tensor &table_id_to_ev_size,
                            int num_lookup, int batch_size, Tensor &src_ids, Tensor &table_ids,
                            Tensor &ev_sizes, Tensor &num_key, cudaStream_t stream) {
  DISPATCH_INTEGRAL_FUNCTION(bucket_range.dtype().type(), offset_t, [&] {
    constexpr int grid_dim_x = 144 * 32;
    constexpr int block_dim_x = 64;
    replicate_bucket_range_kernel<<<grid_dim_x, block_dim_x, sizeof(uint32_t) * (block_dim_x + 1),
                                    stream>>>(
        bucket_range.get<offset_t>(), sorted_lookup_ids.get<int>(), sorted_table_ids.get<int>(),
        table_id_to_ev_size.get<int>(), num_lookup, batch_size, src_ids.get<uint32_t>(),
        table_ids.get<int>(), ev_sizes.get<int>(), num_key.get<size_t>());
  });
}

namespace {
struct LessThan {
  int compare;
  __host__ __device__ __forceinline__ LessThan(int compare) : compare(compare) {}
  __host__ __device__ __forceinline__ bool operator()(const int &a) const { return (a < compare); }
};
}  // namespace

template <typename offset_t>
__global__ void cal_table_range_kernel(const offset_t *bucket_range, const int *sorted_table_ids,
                                       int num_lookup, int *table_range, int batch_size) {
  CUDA_1D_KERNEL_LOOP(idx, num_lookup) {
    if (idx == 0 || sorted_table_ids[idx] != sorted_table_ids[idx - 1]) {
      table_range[idx] = bucket_range[idx * batch_size];
    } else {
      table_range[idx] = std::numeric_limits<int>::max();
    }
  }
  if (threadIdx.x == 0) {
    table_range[num_lookup] = bucket_range[num_lookup * batch_size];
  }
}

void cal_table_range(const Tensor &bucket_range, const Tensor &sorted_table_ids, int num_lookup,
                     Tensor &table_range, int batch_size,
                     LocalReduceIndexCalculationTempStorage &temp_storage, cudaStream_t stream) {
  DISPATCH_INTEGRAL_FUNCTION(bucket_range.dtype().type(), offset_t, [&] {
    constexpr int grid_dim_x = 144 * 8;
    constexpr int block_dim_x = 32;
    cal_table_range_kernel<<<grid_dim_x, block_dim_x, 0, stream>>>(
        bucket_range.get<offset_t>(), sorted_table_ids.get<int>(), num_lookup,
        temp_storage.temp_lookup_range.get<int>(), batch_size);
  });
  LessThan select_op(std::numeric_limits<int>::max());
  size_t temp_storage_nbytes = temp_storage.temp_select_storage.nbytes();
  cub::DeviceSelect::If(temp_storage.temp_select_storage.get(), temp_storage_nbytes,
                        temp_storage.temp_lookup_range.get<int>(), table_range.get<int>(),
                        temp_storage.d_num_selected_table_range_.get<int>(),
                        temp_storage.temp_lookup_range.get_num_elements(), select_op, stream);
}

void partition_by_table_id(const Tensor &keys, const Tensor &bucket_range,
                           const Tensor &sorted_lookup_ids, const Tensor &sorted_table_ids,
                           Tensor &partitioned_keys, Tensor &partitioned_src_ids,
                           const Tensor &table_id_to_ev_size, Tensor &partitioned_bucket_range,
                           Tensor &partitioned_table_range, int num_lookup, int num_table,
                           Tensor &table_ids, Tensor &ev_sizes, Tensor &num_key, int batch_size,
                           LocalReduceIndexCalculationTempStorage &temp_storage,
                           cudaStream_t stream) {
  if (num_table != num_lookup) {
    group_keys_by_lookup_id(keys, bucket_range, sorted_lookup_ids, num_lookup, batch_size,
                            partitioned_keys, partitioned_bucket_range, temp_storage, stream);

  } else {
    partitioned_keys = keys;
    partitioned_bucket_range = bucket_range;
  }

  replicate_bucket_range(partitioned_bucket_range, sorted_lookup_ids, sorted_table_ids,
                         table_id_to_ev_size, num_lookup, batch_size, partitioned_src_ids,
                         table_ids, ev_sizes, num_key, stream);
  cal_table_range(partitioned_bucket_range, sorted_table_ids, num_lookup, partitioned_table_range,
                  batch_size, temp_storage, stream);
}

}  // namespace

template <typename offset_t>
void LocalReduceIndexCalculationTempStorage::init(const std::shared_ptr<CoreResourceManager> &core,
                                                  int num_lookup, int num_table, int batch_size) {
  HugeCTR::CudaDeviceContext ctx(core->get_device_id());
  Device device{DeviceType::GPU, core->get_device_id()};
  auto buffer_ptr = GetBuffer(core);

  {
    size_t temp_bytes = 0;
    cub::DeviceScan::InclusiveSum(nullptr, temp_bytes, (offset_t *)nullptr, (offset_t *)nullptr,
                                  (size_t)num_lookup * batch_size + 1);
    this->temp_scan_storage = buffer_ptr->reserve({temp_bytes}, device, TensorScalarType::Void);
  }

  {
    size_t temp_bytes = 0;
    LessThan select_op(std::numeric_limits<int>::max());
    cub::DeviceSelect::If(nullptr, temp_bytes, (int *)nullptr, (int *)nullptr, (int *)nullptr,
                          num_lookup + 1, select_op);
    this->temp_select_storage = buffer_ptr->reserve({temp_bytes}, device, TensorScalarType::Void);
  }
  this->d_num_selected_table_range_ = buffer_ptr->reserve({1}, device, TensorScalarType::Int32);
  this->temp_lookup_range = buffer_ptr->reserve({num_lookup + 1}, device, TensorScalarType::Int32);
  buffer_ptr->allocate();
}

LocalReduceIndexCalculation::LocalReduceIndexCalculation(std::shared_ptr<CoreResourceManager> core,
                                                         int num_lookup, int num_table,
                                                         int local_hotness_sum, int batch_size,
                                                         DataType key_type) {
  this->core_ = core;

  this->partitioned_result_.init(core, num_lookup, num_table, local_hotness_sum, batch_size,
                                 key_type);
  this->sorted_result.init(core, local_hotness_sum, batch_size, key_type);

  DISPATCH_INTEGRAL_FUNCTION(
      partitioned_result_.partitioned_bucket_range.dtype().type(), offset_t,
      [&] { temp_storage_.init<offset_t>(core, num_lookup, num_table, batch_size); });
}

SegmentedSortDevice::SegmentedSortDevice(const std::shared_ptr<CoreResourceManager> &core,
                                         int max_num_keys, int batch_size, int num_table,
                                         DataType key_type) {
  max_key_num_ = ((size_t)max_num_keys) * ((size_t)batch_size);
  auto buffer_ptr = core::GetBuffer(core);
  DISPATCH_INTEGRAL_FUNCTION(key_type.type(), key_t, [&] {
    cub::DeviceSegmentedSort::SortPairs(nullptr, cub_sort_temp_bytes_, (key_t *)nullptr,
                                        (key_t *)nullptr, (uint32_t *)nullptr, (uint32_t *)nullptr,
                                        max_key_num_, num_table, (int *)nullptr, (int *)nullptr);
    cub_sort_temp_buffer_ =
        buffer_ptr->reserve({cub_sort_temp_bytes_}, core::DeviceType::GPU, TensorScalarType::Void);
  });
  buffer_ptr->allocate();
}

void SegmentedSortDevice::operator()(const embedding::SortInput &input,
                                     embedding::SortOutput &output, cudaStream_t stream) {
  // sort
  DISPATCH_INTEGRAL_FUNCTION(input.keys.dtype().type(), key_t, [&] {
    int num_table = input.unique_table_ids.get_num_elements();
    cub::DeviceSegmentedSort::SortPairs(
        cub_sort_temp_buffer_.get(), cub_sort_temp_bytes_, input.keys.get<key_t>(),
        output.sorted_keys.get<key_t>(), input.src_ids.get<uint32_t>(),
        output.sorted_src_ids.get<uint32_t>(), max_key_num_, num_table,
        input.table_range.get<int>(), input.table_range.get<int>() + 1, stream);
  });
}

template <typename key_t, typename ConversionOp>
__global__ void local_indices_to_global_indices_kernel(const key_t *input_indices, int num_elements,
                                                       const int *table_range,
                                                       const int *unique_table_ids, int num_table,
                                                       const int *table_offsets,
                                                       key_t *output_indices,
                                                       ConversionOp conversion_op, int end_bits) {
  uint32_t num_keys = table_range[num_table];
  CUDA_1D_KERNEL_LOOP(i, num_elements) {
    if (i >= num_keys) {
      // mask unused key
      output_indices[i] = std::numeric_limits<key_t>::max();
      // FIXME: use end_bits so we can save digits that we need to sort
      // output_indices[i] = static_cast<key_t>(1 << end_bits);
      continue;
    }
    int idx_in_table_range = binary_search_index_lower_bound(table_range, num_table + 1, i);
    assert(idx_in_table_range >= 0);

    int table_id = unique_table_ids[idx_in_table_range];
    output_indices[i] = conversion_op(input_indices[i], table_offsets[table_id]);
  }
}

IndicesSort::IndicesSort(const std::shared_ptr<CoreResourceManager> &core,
                         const Tensor &table_id_to_global_start_indices, int end_bit,
                         int max_num_keys, int batch_size, DataType key_type)
    : table_id_to_global_start_indices(table_id_to_global_start_indices), end_bit(end_bit) {
  HCTR_CHECK_HINT(end_bit > 0 && static_cast<size_t>(end_bit) < key_type.itemsize() * 8,
                  "end_bit error");
  auto buffer_ptr = core::GetBuffer(core);
  temp_global_indices =
      buffer_ptr->reserve({max_num_keys * batch_size}, core::DeviceType::GPU, key_type);
  DISPATCH_INTEGRAL_FUNCTION(key_type.type(), key_t, [&] {
    size_t temp_bytes = 0;
    // ATTENTION: cub radix sort requires NumItemT to be consistent
    cub::DeviceRadixSort::SortPairs(nullptr, temp_bytes, (key_t *)nullptr, (key_t *)nullptr,
                                    (uint32_t *)nullptr, (uint32_t *)nullptr,
                                    static_cast<int64_t>(batch_size * max_num_keys));
    d_temp_sort_storage =
        buffer_ptr->reserve({temp_bytes}, core::DeviceType::GPU, TensorScalarType::Void);
  });
  buffer_ptr->allocate();
}

void IndicesSort::operator()(const embedding::SortInput &input, embedding::SortOutput &output,
                             cudaStream_t stream) {
  // 1. add table offset to get global unique indices
  auto key_type = input.keys.dtype();
  HCTR_CHECK_HINT(input.keys.get_num_elements() == temp_global_indices.get_num_elements(),
                  "IndicesSort check input size error");
  DISPATCH_INTEGRAL_FUNCTION(key_type.type(), key_t, [&] {
    auto local_to_global_conversion = [] __device__(const key_t &input_indice, const int &offset) {
      return input_indice + static_cast<key_t>(offset);
    };
    local_indices_to_global_indices_kernel<<<144 * 8, 256, 0, stream>>>(
        input.keys.get<key_t>(), input.keys.get_num_elements(), input.table_range.get<int>(),
        input.unique_table_ids.get<int>(), input.unique_table_ids.get_num_elements(),
        table_id_to_global_start_indices.get<int>(), temp_global_indices.get<key_t>(),
        local_to_global_conversion, end_bit);
  });

  // 2. sort
  DISPATCH_INTEGRAL_FUNCTION(key_type.type(), key_t, [&] {
    size_t temp_bytes = d_temp_sort_storage.nbytes();
    cub::DeviceRadixSort::SortPairs(
        d_temp_sort_storage.get(), temp_bytes, temp_global_indices.get<key_t>(),
        output.sorted_keys.get<key_t>(), input.src_ids.get<uint32_t>(),
        output.sorted_src_ids.get<uint32_t>(), temp_global_indices.get_num_elements(), 0,
        sizeof(key_t) * 8, stream);
  });

  // 3. global unique indices to local indices
  DISPATCH_INTEGRAL_FUNCTION(key_type.type(), key_t, [&] {
    auto global_to_local_conversion = [] __device__(const key_t &input_indice, const int &offset) {
      return input_indice - static_cast<key_t>(offset);
    };
    local_indices_to_global_indices_kernel<<<144 * 8, 256, 0, stream>>>(
        output.sorted_keys.get<key_t>(), input.keys.get_num_elements(),
        input.table_range.get<int>(), input.unique_table_ids.get<int>(),
        input.unique_table_ids.get_num_elements(), table_id_to_global_start_indices.get<int>(),
        output.sorted_keys.get<key_t>(), global_to_local_conversion, end_bit);
  });
}

template <typename key_t>
__global__ void get_keys_flag(const key_t *__restrict__ sorted_keys,
                              const int *__restrict__ table_ids, const size_t *__restrict__ num_key,
                              size_t *__restrict__ key_flag_buffer) {
  CUDA_1D_KERNEL_LOOP(tid, *num_key) {
    key_t local_key = sorted_keys[tid];
    int table_id = table_ids[tid];
    size_t is_first = 0;
    if ((tid == 0) ||
        ((tid > 0) && ((sorted_keys[tid - 1] != local_key) || (table_ids[tid - 1] != table_id))))
      is_first = 1;
    key_flag_buffer[tid] = is_first;
  }
}

template <typename key_t>
__global__ void get_unique_key(const key_t *__restrict__ sorted_keys,
                               const int *__restrict__ table_ids,
                               const size_t *__restrict__ key_flag_buffer,
                               const size_t *__restrict__ num_key, key_t *__restrict__ unique_keys,
                               int *__restrict__ unique_table_ids,
                               size_t *__restrict__ unique_key_num,
                               uint32_t *__restrict__ dst_ids) {
  int key_num = *num_key;
  CUDA_1D_KERNEL_LOOP(tid, key_num) {
    size_t key_buffer = key_flag_buffer[tid];  // need size_t?
    dst_ids[tid] = key_buffer - 1;
    if ((tid > 0 && key_flag_buffer[tid - 1] != key_buffer) || tid == 0) {
      unique_keys[key_buffer - 1] = sorted_keys[tid];
      unique_table_ids[key_buffer - 1] = table_ids[tid];
    }
  }

  if (blockIdx.x * blockDim.x + threadIdx.x == 0) {
    *unique_key_num = key_flag_buffer[key_num - 1];
  }
}

SegmentdUnique::SegmentdUnique(const std::shared_ptr<CoreResourceManager> &core, int max_num_keys,
                               int batch_size) {
  auto buffer_ptr = core::GetBuffer(core);
  max_key_num_ = ((size_t)max_num_keys) * ((size_t)batch_size);
  key_flag_buffer_ =
      buffer_ptr->reserve({max_key_num_}, core::DeviceType::GPU, TensorScalarType::Size_t);

  cub::DeviceScan::InclusiveSum(nullptr, cub_scan_temp_bytes_, (size_t *)nullptr, (size_t *)nullptr,
                                max_key_num_);
  cub_scan_temp_buffer_ =
      buffer_ptr->reserve({cub_scan_temp_bytes_}, core::DeviceType::GPU, TensorScalarType::Void);
  buffer_ptr->allocate();
}

void SegmentdUnique::operator()(const Tensor &sorted_keys, const Tensor &table_ids,
                                const Tensor &key_num, Tensor &unique_keys,
                                Tensor &unique_table_ids, Tensor &num_unique_keys, Tensor &dst_ids,
                                cudaStream_t stream) {
  auto key_type = sorted_keys.dtype();
  DISPATCH_INTEGRAL_FUNCTION(key_type.type(), key_t, [&] {
    get_keys_flag<<<144 * 8, 256, 0, stream>>>(sorted_keys.get<key_t>(), table_ids.get<int>(),
                                               key_num.get<size_t>(),
                                               key_flag_buffer_.get<size_t>());
  });

  DISPATCH_INTEGRAL_FUNCTION(key_type.type(), key_t, [&] {
    size_t temp_bytes = cub_scan_temp_buffer_.nbytes();
    cub::DeviceScan::InclusiveSum(cub_scan_temp_buffer_.get(), temp_bytes,
                                  key_flag_buffer_.get<size_t>(), key_flag_buffer_.get<size_t>(),
                                  max_key_num_, stream);
  });

  DISPATCH_INTEGRAL_FUNCTION(key_type.type(), key_t, [&] {
    get_unique_key<<<144 * 8, 256, 0, stream>>>(
        sorted_keys.get<key_t>(), table_ids.get<int>(), key_flag_buffer_.get<size_t>(),
        key_num.get<size_t>(), unique_keys.get<key_t>(), unique_table_ids.get<int>(),
        num_unique_keys.get<size_t>(), dst_ids.get<uint32_t>());
  });
}

template <typename key_t>
__global__ void get_ids_flag(const key_t *__restrict__ sorted_keys, const int *table_range,
                             int table_num, uint32_t *__restrict__ ids_buffer) {
  size_t key_num = table_range[table_num];
  CUDA_1D_KERNEL_LOOP(tid, key_num) {
    int table_index = binary_search_index_lower_bound(table_range, table_num + 1, tid);
    key_t local_key;
    local_key = sorted_keys[tid];
    size_t is_first = 0;
    if (tid > 0 && ((sorted_keys[tid - 1] != local_key) || (tid == table_range[table_index])))
      is_first = 1;
    ids_buffer[tid] = is_first;
  }
}

CalDstIds::CalDstIds(const std::shared_ptr<CoreResourceManager> &core, int max_num_keys,
                     int batch_size) {
  auto buffer_ptr = core::GetBuffer(core);
  max_key_num_ = ((size_t)max_num_keys) * ((size_t)batch_size);
  cub::DeviceScan::InclusiveSum(nullptr, cub_scan_temp_bytes_, (uint32_t *)nullptr,
                                (uint32_t *)nullptr, max_key_num_);
  cub_scan_temp_buffer_ =
      buffer_ptr->reserve({cub_scan_temp_bytes_}, core::DeviceType::GPU, TensorScalarType::Void);
  buffer_ptr->allocate();
}

void CalDstIds::operator()(Tensor &sorted_keys, int num_table, const Tensor &table_range,
                           Tensor &dst_ids, cudaStream_t stream) {
  auto key_type = sorted_keys.dtype();
  DISPATCH_INTEGRAL_FUNCTION(key_type.type(), key_t, [&] {
    get_ids_flag<<<144 * 8, 256, 0, stream>>>(sorted_keys.get<key_t>(), table_range.get<int>(),
                                              num_table, dst_ids.get<uint32_t>());
  });

  cub::DeviceScan::InclusiveSum(cub_scan_temp_buffer_.get(), cub_scan_temp_bytes_,
                                dst_ids.get<uint32_t>(), dst_ids.get<uint32_t>(), max_key_num_,
                                stream);
}

void intra_partition_sort(const Tensor &keys, const Tensor &src_ids, const Tensor &table_range,
                          const Tensor &unique_table_ids, Tensor &sorted_keys,
                          Tensor &sorted_src_ids, Tensor &dst_ids, SortKeyAndSrcIdOp sort_op,
                          CalDstIds &cal_dst_ids_kernel, cudaStream_t stream) {
  SortInput input{keys, src_ids, table_range, unique_table_ids};
  SortOutput output{sorted_keys, sorted_src_ids};
  sort_op(input, output, stream);
}

__global__ void get_unique_valid_range(const int *__restrict__ unique_key_table_ids,
                                       const size_t *num_unique_key, int table_num,
                                       uint32_t *__restrict__ unique_table_range) {
  CUDA_1D_KERNEL_LOOP(tid, table_num + 1) { unique_table_range[tid] = 0; }
  size_t key_num = *num_unique_key;
  CUDA_1D_KERNEL_LOOP(tid, key_num) {
    if (tid > 0 && unique_key_table_ids[tid] != unique_key_table_ids[tid - 1]) {
      unique_table_range[unique_key_table_ids[tid - 1] + 1] = tid;
    }
    if (tid == 0) {
      unique_table_range[table_num] = key_num;
    }
  }
}

__global__ void fill_unique_range(uint32_t *__restrict__ unique_table_range, int table_num) {
  CUDA_1D_KERNEL_LOOP(tid, table_num - 1) {
    int table_start = tid + 1;
    while (table_start < table_num && unique_table_range[table_start] < unique_table_range[tid]) {
      unique_table_range[table_start] = unique_table_range[tid];
      table_start++;
    }
  }
}

void get_unique_range(const Tensor &unique_table_ids, Tensor &unique_table_ranges,
                      Tensor &num_unique_key, int table_num, cudaStream_t stream) {
  get_unique_valid_range<<<144 * 8, 256, 0, stream>>>(unique_table_ids.get<int>(),
                                                      num_unique_key.get<size_t>(), table_num,
                                                      unique_table_ranges.get<uint32_t>());
  fill_unique_range<<<144 * 8, 256, 0, stream>>>(unique_table_ranges.get<uint32_t>(), table_num);
}

__global__ void get_dst_length_per_key(const int *__restrict__ unique_key_table_ids,
                                       const int *table_id_to_evsizes,
                                       const uint64_t *num_unique_keys, uint32_t *dst_key_offset) {
  CUDA_1D_KERNEL_LOOP(tid, *num_unique_keys) {
    int table_id = unique_key_table_ids[tid];
    dst_key_offset[tid] = table_id_to_evsizes[table_id];
  }
}

CalDstOffsetMP::CalDstOffsetMP(const std::shared_ptr<CoreResourceManager> &core, int max_num_keys,
                               int batch_size) {
  auto buffer_ptr = core::GetBuffer(core);
  max_key_num_ = ((size_t)max_num_keys) * ((size_t)batch_size);
  cub::DeviceScan::ExclusiveSum(nullptr, cub_scan_temp_bytes_, (uint32_t *)nullptr,
                                (uint32_t *)nullptr, max_key_num_);
  cub_scan_temp_buffer_ =
      buffer_ptr->reserve({cub_scan_temp_bytes_}, core::DeviceType::GPU, TensorScalarType::UInt32);
  buffer_ptr->allocate();
}

void CalDstOffsetMP::operator()(const Tensor &unique_key_table_ids,
                                const Tensor &table_id_to_evsizes, const Tensor &num_unique_keys,
                                Tensor &dst_key_offset, cudaStream_t stream) {
  get_dst_length_per_key<<<144 * 8, 256, 0, stream>>>(
      unique_key_table_ids.get<int>(), table_id_to_evsizes.get<int>(),
      num_unique_keys.get<uint64_t>(), dst_key_offset.get<uint32_t>());

  size_t temp_bytes = cub_scan_temp_buffer_.nbytes();
  cub::DeviceScan::ExclusiveSum(cub_scan_temp_buffer_.get(), temp_bytes,
                                dst_key_offset.get<uint32_t>(), dst_key_offset.get<uint32_t>(),
                                max_key_num_, stream);

  HCTR_LIB_THROW(cudaStreamSynchronize(stream));
}

void unique_keys(const Tensor &sorted_keys, const Tensor &table_ids, const Tensor &num_key,
                 Tensor &unique_keys, Tensor &num_unique_keys, Tensor &reduction_table_ids,
                 Tensor &dst_ids, SegmentdUnique &segmented_unique_kernel, cudaStream_t stream) {
  segmented_unique_kernel(sorted_keys, table_ids, num_key, unique_keys, reduction_table_ids,
                          num_unique_keys, dst_ids, stream);
}

void LocalReduceIndexCalculation::cal_for_sparse_input(const EmbeddingInput &embedding_input,
                                                       SortKeyAndSrcIdOp sort_key_and_src_id_op,
                                                       SegmentdUnique &segmented_unique,
                                                       CalDstIds &cal_dst_ids,
                                                       ReductionIndices &reduction_indices,
                                                       Wgrad &wgrad, int batch_size) {
  HugeCTR::CudaDeviceContext ctx(core_->get_device_id());
  auto stream = core_->get_local_gpu()->get_stream();
  HCTR_LIB_THROW(cudaGetLastError());
  auto &unique_table_ids = wgrad.attr.get_unique_table_ids();
  partition_by_table_id(
      embedding_input.keys, embedding_input.bucket_range, wgrad.attr.sorted_lookup_ids,
      wgrad.attr.sorted_table_ids, partitioned_result_.partitioned_keys,
      partitioned_result_.partitioned_src_ids, wgrad.attr.table_id_to_ev_size,
      partitioned_result_.partitioned_bucket_range, partitioned_result_.partitioned_table_range,
      wgrad.attr.num_lookup, wgrad.attr.num_table, reduction_indices.table_ids,
      reduction_indices.ev_sizes, reduction_indices.num_key, batch_size, temp_storage_, stream);
  HCTR_LIB_THROW(cudaGetLastError());

  intra_partition_sort(partitioned_result_.partitioned_keys,
                       partitioned_result_.partitioned_src_ids,
                       partitioned_result_.partitioned_table_range, unique_table_ids,
                       sorted_result.sorted_keys, reduction_indices.src_ids,
                       reduction_indices.dst_ids, sort_key_and_src_id_op, cal_dst_ids, stream);
  HCTR_LIB_THROW(cudaGetLastError());

  reduction_indices.num_elements = embedding_input.h_num_keys;

  unique_keys(sorted_result.sorted_keys, reduction_indices.table_ids, reduction_indices.num_key,
              wgrad.unique_keys, wgrad.num_unique_keys, wgrad.table_ids, reduction_indices.dst_ids,
              segmented_unique, stream);

  HCTR_LIB_THROW(cudaStreamSynchronize(stream));
}

void LocalReduceIndexCalculation::cal_unique_key_table_range(Wgrad &wgrad) {
  HugeCTR::CudaDeviceContext ctx(core_->get_device_id());
  auto stream = core_->get_local_gpu()->get_stream();
  get_unique_range(wgrad.table_ids, wgrad.table_range, wgrad.num_unique_keys, wgrad.attr.num_table,
                   stream);
}

void LocalReduceIndexCalculation::cal_dst_ev_start(
    Wgrad &wgrad, WgradEvStartIndicesCalculationOp cal_ev_start_indices_in_wgrad) {
  HugeCTR::CudaDeviceContext ctx(core_->get_device_id());
  auto stream = core_->get_local_gpu()->get_stream();

  WgradEvStartIndicesCalculationInput input{
      wgrad.unique_keys, wgrad.num_unique_keys,          wgrad.attr.get_unique_table_ids(),
      wgrad.table_range, wgrad.attr.table_id_to_ev_size, wgrad.table_ids};
  WgradEvStartIndicesCalculationOutput output{wgrad.ev_start_indices};
  cal_ev_start_indices_in_wgrad(input, output, stream);
}
}  // namespace embedding
