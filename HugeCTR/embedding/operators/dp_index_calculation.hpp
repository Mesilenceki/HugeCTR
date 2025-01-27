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
#pragma once

#include "HugeCTR/core/buffer.hpp"
#include "HugeCTR/core/registry.hpp"
#include "index_calculation.hpp"

namespace embedding {
using core::CoreResourceManager;
using core::DataType;
using core::Device;
using core::DeviceType;
using core::Shape;
using core::Tensor;
using core::TensorList;
using core::TensorScalarType;

struct DPKeySelector {
  int num_lookup_before_filter;
  Tensor lookup_ids;
  int num_lookup_after_filter;

  int gpu_id;
  int num_gpus;

  int max_num_keys_before_filter;
  int max_num_keys_after_filter;
};

using DPIndexCalculation = IndexCalculation<DPKeySelector>;

struct DenseAllreduceIndexCalculation {
  std::shared_ptr<CoreResourceManager> core_;
  LocalReduceIndexCalculation local_reduce_index_calculation_;
  IndicesSort indices_sort_;
  CalDstIds cal_dst_ids_;
  SegmentdUnique segmented_unique_;

  void cal_for_sparse_indices(const EmbeddingInput& embedding_input,
                              const Tensor& table_id_to_allreduce_buffer_start_indices,
                              const Tensor& ev_start_indices_in_allreduce_buffer,
                              ReductionIndices& reduction_indices, Wgrad& wgrad, int batch_size);
};

struct BroadcastResult {
  Tensor h_table_range_;
  Tensor allgather_table_range_;
  Tensor reordered_allgather_table_range_;
  Tensor h_reordered_allgather_table_range_;
  Tensor allgather_unique_keys_;
};

template <typename key_t>
struct TableEntry {
  key_t key;
  uint32_t value;
};

struct HashTable {
  Tensor hash_table_;
  Tensor d_temp_scan_table_range_storage_;
};

struct SparseAllreduceCalEVStartIndicesTempStorage {
  Tensor mask_unique_keys_in_allgather_unique_keys_;
  Tensor d_temp_select_temp_storage_;
  Tensor d_temp_scan_ev_start_indices_storage_;
  Tensor unique_idx_;
  Tensor d_temp_scan_unique_idx_temp_storage_;
};

struct SparseAllreduceCalEVStartIndicesStorage {
  BroadcastResult broadcast_result_;
  HashTable hash_table_;
  SparseAllreduceCalEVStartIndicesTempStorage temp_storage_;

  SparseAllreduceCalEVStartIndicesStorage() = default;

  SparseAllreduceCalEVStartIndicesStorage(std::shared_ptr<CoreResourceManager> core, int num_table,
                                          int local_hotness_sum, int batch_size, DataType key_type);
};

struct SparseAllreduceIndexCalculation {
  std::shared_ptr<CoreResourceManager> core_;
  LocalReduceIndexCalculation local_reduce_index_calculation_;
  SegmentedSortDevice segmented_sort_device_;
  CalDstIds cal_dst_ids_;
  SegmentdUnique segmented_unique_;

  SparseAllreduceCalEVStartIndicesStorage cal_ev_start_indices_storage_;

  void cal_for_sparse_input(const EmbeddingInput& embedding_input,
                            ReductionIndices& reduction_indices, Wgrad& local_reduce_wgrad,
                            Wgrad& allreduce_wgrad, int batch_size);
};

struct DPLocalReduceIndexCalculation {
  SparseAllreduceIndexCalculation sparse_allreduce_index_calculation;
  DenseAllreduceIndexCalculation dense_allreduce_index_calculation;
};
}  // namespace embedding
