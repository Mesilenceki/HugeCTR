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
#include "HugeCTR/include/utils.cuh"
#include "HugeCTR/include/utils.hpp"
#include "generic_lookup.cuh"
#include "model_forward.hpp"
namespace embedding {
using HugeCTR::CudaDeviceContext;

DPModelForward::DPModelForward(std::shared_ptr<CoreResourceManager> core, int num_gpus,
                               int num_embedding, int num_local_embedding)
    : core_(core),
      num_gpus_(num_gpus),
      num_embedding_(num_embedding),
      num_local_embedding_(num_local_embedding) {}

namespace {

void dp_forward_to_feature_major_output(const TensorList &lookup_res,
                                        const Tensor &dp_feature_major_bucket_range,
                                        const Tensor &local_lookup_ids,
                                        EmbeddingOutput &embedding_output, int batch_size_per_gpu,
                                        int gpu_id, int num_gpus, cudaStream_t stream) {
  int num_local_lookup = local_lookup_ids.get_num_elements();
  int batch_size = num_gpus * batch_size_per_gpu;
  auto &output_buffer = embedding_output.data;
  const auto &embedding_output_attr = embedding_output.attr;

  DISPATCH_INTEGRAL_FUNCTION(dp_feature_major_bucket_range.dtype().type(), offset_t, [&] {
    DISPATCH_FLOAT_AND_HALF_FUNCTION(output_buffer.dtype().type(), emb_t, [&] {
      const int *local_lookup_ids_ptr = local_lookup_ids.get<int>();
      const offset_t *bucket_range_ptr = dp_feature_major_bucket_range.get<offset_t>();
      const int *dst_id_to_ev_size_ptr = embedding_output_attr.id_to_ev_size.get<int>();
      const int *dst_id_to_ev_start_indices_ptr =
          embedding_output_attr.id_to_ev_start_indices.get<int>();
      const char *dst_id_to_combiner_ptr = embedding_output_attr.id_to_combiner.get<char>();

      const float **lookup_res_ptr = lookup_res.get<float>();
      emb_t *output_buffer_ptr = output_buffer.get<emb_t>();

      auto multi_to_one_desc = make_MultiToOne<float, emb_t>(
          batch_size_per_gpu * num_local_lookup,
          [=] __device__(int i) { return bucket_range_ptr[i]; },
          [=] __device__(int i) {
            int pooling_factor = static_cast<int>(bucket_range_ptr[i + 1] - bucket_range_ptr[i]);

            int lookup_id = local_lookup_ids_ptr[i / batch_size_per_gpu];
            return dst_id_to_combiner_ptr[lookup_id] == static_cast<char>(Combiner::Average)
                       ? pooling_factor
                       : 1;
          },
          [=] __device__(int i) {
            int lookup_id = local_lookup_ids_ptr[i / batch_size_per_gpu];
            return dst_id_to_ev_size_ptr[lookup_id];
          },
          [=] __device__(int i) { return lookup_res_ptr[i]; },
          [=] __device__(int i) {
            int lookup_id = local_lookup_ids_ptr[i / batch_size_per_gpu];
            int bid = i % batch_size_per_gpu;
            int ev_size = dst_id_to_ev_size_ptr[lookup_id];
            return output_buffer_ptr +
                   batch_size_per_gpu * dst_id_to_ev_start_indices_ptr[lookup_id] + bid * ev_size;
          });
      copy_multi_to_one(multi_to_one_desc, embedding_output_attr.max_ev_size, stream);
    });
  });
}

void dp_forward_to_batch_major_output(const TensorList &lookup_res,
                                      const Tensor &dp_feature_major_bucket_range,
                                      const Tensor &local_lookup_ids,
                                      EmbeddingOutput &embedding_output, int batch_size_per_gpu,
                                      int gpu_id, int num_gpus, cudaStream_t stream) {
  int num_local_lookup = local_lookup_ids.get_num_elements();
  int batch_size = num_gpus * batch_size_per_gpu;
  auto &output_buffer = embedding_output.data;
  const auto &embedding_output_attr = embedding_output.attr;
  int num_lookup = embedding_output_attr.id_to_ev_size.get_num_elements();

  DISPATCH_INTEGRAL_FUNCTION(dp_feature_major_bucket_range.dtype().type(), offset_t, [&] {
    DISPATCH_FLOAT_AND_HALF_FUNCTION(output_buffer.dtype().type(), emb_t, [&] {
      const int *local_lookup_ids_ptr = local_lookup_ids.get<int>();
      const offset_t *bucket_range_ptr = dp_feature_major_bucket_range.get<offset_t>();
      const int *dst_id_to_ev_size_ptr = embedding_output_attr.id_to_ev_size.get<int>();
      const int *dst_id_to_ev_start_indices_ptr =
          embedding_output_attr.id_to_ev_start_indices.get<int>();
      const char *dst_id_to_combiner_ptr = embedding_output_attr.id_to_combiner.get<char>();

      const float **lookup_res_ptr = lookup_res.get<float>();
      emb_t *output_buffer_ptr = output_buffer.get<emb_t>();

      auto multi_to_one_desc = make_MultiToOne<float, emb_t>(
          batch_size_per_gpu * num_local_lookup,
          [=] __device__(int i) { return bucket_range_ptr[i]; },
          [=] __device__(int i) {
            int pooling_factor = static_cast<int>(bucket_range_ptr[i + 1] - bucket_range_ptr[i]);

            int lookup_id = local_lookup_ids_ptr[i / batch_size_per_gpu];
            return dst_id_to_combiner_ptr[lookup_id] == static_cast<char>(Combiner::Average)
                       ? pooling_factor
                       : 1;
          },
          [=] __device__(int i) {
            int lookup_id = local_lookup_ids_ptr[i / batch_size_per_gpu];
            return dst_id_to_ev_size_ptr[lookup_id];
          },
          [=] __device__(int i) { return lookup_res_ptr[i]; },
          [=] __device__(int i) {
            int lookup_id = local_lookup_ids_ptr[i / batch_size_per_gpu];
            int bid = i % batch_size_per_gpu;
            return output_buffer_ptr + bid * dst_id_to_ev_start_indices_ptr[num_lookup] +
                   dst_id_to_ev_start_indices_ptr[lookup_id];
          });
      copy_multi_to_one(multi_to_one_desc, embedding_output_attr.max_ev_size, stream);
    });
  });
}
}  // namespace

void DPModelForward::compute(const TensorList &lookup_res,
                             const Tensor &dp_feature_major_bucket_range,
                             const Tensor &local_lookup_ids, EmbeddingOutput &embedding_output,
                             int batch_size_per_gpu) {
  CudaDeviceContext ctx(core_->get_device_id());
  auto stream = core_->get_local_gpu()->get_stream();
  int gpu_id = core_->get_global_gpu_id();
  int num_gpus = core_->get_global_gpu_count();

  if (embedding_output.attr.layout == EmbeddingLayout::FeatureMajor) {
    dp_forward_to_feature_major_output(lookup_res, dp_feature_major_bucket_range, local_lookup_ids,
                                       embedding_output, batch_size_per_gpu, gpu_id, num_gpus,
                                       stream);
  } else {
    dp_forward_to_batch_major_output(lookup_res, dp_feature_major_bucket_range, local_lookup_ids,
                                     embedding_output, batch_size_per_gpu, gpu_id, num_gpus,
                                     stream);
  }
}

void ModelForward::compute(const TensorList &mp_ev, const Tensor &bucket_range,
                           ModelCommBuffer &model_comm_buffer, int batch_size) {
  CudaDeviceContext ctx(core_->get_device_id());
  int batch_size_per_gpu = batch_size / model_comm_buffer.attr.num_gpus;
  auto stream = core_->get_local_gpu()->get_stream();

  int num_lookup = model_comm_buffer.attr.num_lookup;
  if (num_lookup > 0) {
    DISPATCH_FLOAT_AND_HALF_FUNCTION(model_comm_buffer.attr.type.type(), emb_t, [&] {
      const uint32_t *bucket_range_ptr = bucket_range.get<uint32_t>();
      const int *id_to_ev_size_ptr = model_comm_buffer.attr.id_to_ev_size.get<int>();
      const int *id_to_ev_start_indices_ptr =
          model_comm_buffer.attr.id_to_ev_start_indices.get<int>();
      const float **mp_ev_ptr = mp_ev.get<float>();
      emb_t **model_comm_buffer_ptr = model_comm_buffer.data.get<emb_t>();

      auto multi_to_one_desc = make_MultiToOne<float, emb_t>(
          batch_size * num_lookup, [=] __device__(int i) { return bucket_range_ptr[i]; },
          [=] __device__(int i) { return 1; },
          [=] __device__(int i) {
            int i_lookup = i / batch_size;
            return id_to_ev_size_ptr[i_lookup];
          },
          [=] __device__(int i) { return mp_ev_ptr[i]; },
          [=] __device__(int i) {
            int i_lookup = i / batch_size;
            int batch_id = i % batch_size;
            int gpu_id = batch_id / batch_size_per_gpu;
            int ev_size = id_to_ev_size_ptr[i_lookup];
            int local_batch_id = batch_id % batch_size_per_gpu;
            return model_comm_buffer_ptr[gpu_id] +
                   batch_size_per_gpu * id_to_ev_start_indices_ptr[i_lookup] +
                   local_batch_id * ev_size;
          });
      copy_multi_to_one(multi_to_one_desc, model_comm_buffer.attr.max_ev_size, stream);
    });
  }
}

void ModelCommBufferAttr::init(std::shared_ptr<CoreResourceManager> core,
                               const EmbeddingCollectionParam &ebc_param, size_t grouped_id) {
  HugeCTR::CudaDeviceContext context(core->get_device_id());
  int gpu_id = core->get_global_gpu_id();

  std::vector<int> h_id_to_ev_size;
  for (int lookup_id = 0; lookup_id < ebc_param.num_lookup; ++lookup_id) {
    if (!ebc_param.has_table_shard(gpu_id, grouped_id, lookup_id)) continue;

    const auto &lookup_params = ebc_param.lookup_params;
    int ev_size = lookup_params[lookup_id].ev_size;
    h_id_to_ev_size.push_back(ev_size);
  }
  std::vector<int> h_id_to_ev_start_indices{0};
  std::partial_sum(h_id_to_ev_size.begin(), h_id_to_ev_size.end(),
                   std::back_inserter(h_id_to_ev_start_indices));

  auto buffer_ptr = GetBuffer(core);
  this->id_to_ev_size =
      buffer_ptr->reserve({h_id_to_ev_size.size()}, DeviceType::GPU, TensorScalarType::Int32);
  this->id_to_ev_start_indices = buffer_ptr->reserve({h_id_to_ev_start_indices.size()},
                                                     DeviceType::GPU, TensorScalarType::Int32);
  buffer_ptr->allocate();
  this->id_to_ev_size.copy_from(h_id_to_ev_size);
  this->id_to_ev_start_indices.copy_from(h_id_to_ev_start_indices);
  this->num_lookup = static_cast<int>(h_id_to_ev_size.size());
  this->num_gpus = static_cast<int>(core->get_global_gpu_count());
  this->max_ev_elements = std::accumulate(h_id_to_ev_size.begin(), h_id_to_ev_size.end(), 0);

  this->layout = EmbeddingLayout::FeatureMajor;
  this->max_ev_size = h_id_to_ev_size.empty()
                          ? 0
                          : *std::max_element(h_id_to_ev_size.begin(), h_id_to_ev_size.end());
  this->is_ragged = true;
  this->is_aligned = false;
  this->type = ebc_param.emb_type;
}

void ModelCommBuffer::init(std::shared_ptr<CoreResourceManager> core,
                           const ModelCommBufferAttr &attr, int batch_size) {
  HugeCTR::CudaDeviceContext context(core->get_device_id());
  this->data_list.clear();

  auto buffer_ptr = GetBuffer(core);
  for (int gpu_id = 0; gpu_id < attr.num_gpus; ++gpu_id) {
    this->data_list.push_back(buffer_ptr->reserve(
        {batch_size * attr.max_ev_elements / attr.num_gpus}, core::DeviceType::GPU, attr.type));
  }
  buffer_ptr->allocate();

  this->data = TensorList(core.get(), this->data_list, DeviceType::GPU, attr.type);

  this->attr = attr;
}

void ModelCommBuffer::init_from_device_buffer(std::shared_ptr<CoreResourceManager> core,
                                              const std::vector<Tensor> &data_buffer_list,
                                              const ModelCommBufferAttr &attr) {
  this->data_list = data_buffer_list;
  this->data = TensorList(core.get(), this->data_list, DeviceType::GPU, attr.type);
  this->attr = attr;
}

}  // namespace embedding
