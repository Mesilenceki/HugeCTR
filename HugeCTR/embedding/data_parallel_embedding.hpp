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

#include "common.hpp"
#include "embedding.hpp"
#include "operators/communication.hpp"
#include "operators/compress_offset.hpp"
#include "operators/dp_index_calculation.hpp"
#include "operators/model_backward.hpp"
#include "operators/model_forward.hpp"

namespace embedding {

struct UniformDataParallelEmbeddingMeta {
  mutable std::vector<int> h_hotness_list_;
  mutable int num_hotness_;
  mutable std::vector<int> h_local_hotness_list_;
  mutable int num_local_hotness_;

  int num_lookup_;
  std::vector<int> h_ev_size_list_;
  int max_ev_size_;
  std::vector<int> h_ev_size_offset_;
  Tensor d_ev_size_offset_;

  std::vector<char> h_combiner_list_;
  Tensor d_combiner_list_;

  int num_local_lookup_;

  std::vector<char> h_local_combiner_list_;

  std::vector<int> h_local_lookup_id_list_;
  Tensor d_local_lookup_id_list_;

  std::vector<int> h_local_ev_size_list_;
  Tensor d_local_ev_size_list_;

  std::vector<int> h_local_table_id_list_;
  Tensor d_local_table_id_list_;

  WgradAttr wgrad_attr;

  std::vector<int> h_table_id_to_global_start_indices;
  Tensor table_id_to_global_start_indices;
  Tensor table_id_to_allreduce_buffer_start_indices;

  KernelParams kernel_params;

  UniformDataParallelEmbeddingMeta(std::shared_ptr<CoreResourceManager> core,
                                   const EmbeddingCollectionParam &ebc_param, size_t grouped_id);

  void update_mutable_meta(std::shared_ptr<CoreResourceManager> core,
                           const EmbeddingCollectionParam &ebc_param, size_t grouped_id) const;
};

class UniformDPEmbedding : public IGroupedEmbeddingOp {
  std::shared_ptr<CoreResourceManager> core_;
  UniformDataParallelEmbeddingMeta meta_;

  ReductionIndices reduction_indices_;
  DPLocalReduceIndexCalculation local_reduce_index_calculation_;
  LocalReduce local_reduce_;
  Wgrad local_reduce_indices_;

  CompressOffset compress_offset_;
  DPModelForward dp_model_forward_;
  AverageCombiner average_combiner_;

  NcclAllReduceInplaceComm allreduce_comm_;

  TensorList embedding_vec_;

  void backward_per_gpu_for_indices_only(const EmbeddingInput &embedding_input,
                                         const embedding::EmbeddingOutput &top_grad,
                                         embedding::Wgrad &wgrad, int batch_size);

  void backward_per_gpu_for_dynamic_table(const EmbeddingInput &embedding_input,
                                          const embedding::EmbeddingOutput &top_grad,
                                          embedding::Wgrad &wgrad, int batch_size);

 public:
  UniformDPEmbedding(std::shared_ptr<CoreResourceManager> core,
                     const EmbeddingCollectionParam &params, size_t grouped_id);

  void forward_per_gpu(const EmbeddingInput &embedding_input, ILookup *embedding_table,
                       EmbeddingOutput &embedding_output, int batch_size) override;

  void backward_per_gpu(const EmbeddingInput &embedding_input, const EmbeddingOutput &top_grad,
                        Wgrad &wgrad, int batch_size) override;

  const WgradAttr &get_wgrad_attr() const override { return meta_.wgrad_attr; }
};
}  // namespace embedding
