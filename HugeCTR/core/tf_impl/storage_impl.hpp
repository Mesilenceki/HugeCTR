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

#include <cuda_runtime.h>

#include "../core.hpp"
#include "../device.hpp"
#include "tensorflow/core/common_runtime/gpu/gpu_process_state.h"
#include "tensorflow/core/framework/allocator.h"
#include "tensorflow/core/framework/op_kernel.h"
#include "tensorflow/core/framework/tensor.h"
#include "tensorflow/core/protobuf/config.pb.h"

namespace tf_internal {

using core::Device;
using core::DeviceType;
using core::IStorageImpl;
using core::Storage;

using tensorflow::AllocationAttributes;
using tensorflow::Allocator;
using tensorflow::AllocatorAttributes;
using tensorflow::DataType;
using tensorflow::DT_UINT8;
using tensorflow::GPUOptions;
using tensorflow::GPUProcessState;
using tensorflow::Tensor;
using tensorflow::TensorShape;
using tensorflow::TfDeviceId;
using tensorflow::errors::ResourceExhausted;

// We suppose one allocation can not allocate more than 1 TB
constexpr size_t MAX_MEMORY_SIZE = 1024 * 1024 * 1024 * 1024lu;

class TFStorageImpl final : public IStorageImpl {
 public:
  TFStorageImpl(Allocator *allocator = nullptr)
      : allocated_(false), on_gpu_(true), gpu_id_(0), cpu_id_(0), total_size_(0), ptr_(nullptr) {
    gpu_option_.set_allow_growth(true);
  }

  TFStorageImpl(Device &device)
      : allocated_(false), on_gpu_(true), gpu_id_(0), cpu_id_(0), total_size_(0), ptr_(nullptr) {
    gpu_option_.set_allow_growth(true);
    if (device.type() == DeviceType::GPU) {
      set_on_gpu(true);
      set_gpu_id(device.index());
    } else if (device.type() == DeviceType::CPU || device.type() == DeviceType::CPUGPU) {
      set_on_gpu(false);
      // TODO(@hrong): if support numa nodes in HCTR core, replace `0` to
      // `device.index()`.
      set_cpu_id(0);
    } else {
      LOG(FATAL) << "Invalid Device type: " << device.type();
    }
  }

  DISALLOW_COPY_AND_MOVE(TFStorageImpl)

  ~TFStorageImpl() {
    if (allocated_) {
      delete out_tensor_;
    }
  }

  void *get_ptr() override {
    if (!ptr_ || !allocated_) {
      LOG(WARNING) << "Tensor is not allocated. You forget call allocate()?";
    }
    return ptr_;
  }

  const Tensor *get_tensor() { return static_cast<const Tensor *>(out_tensor_); }

  size_t nbytes() const override { return total_size_; }

  void extend(size_t s) override {
    if (s > MAX_MEMORY_SIZE) {
      LOG(FATAL) << "out of memory for reserving memory: " << s;
      return;
    }
    total_size_ += s;
  }

  void allocate() override {
    if (allocated_) {
      LOG(FATAL) << "InternalBuffer has been allocated!";
      return;
    }

    if (total_size_ < 0) {
      LOG(FATAL) << "InternalBuffer size_in_bytes should >= 0";
      return;
    }

    DataType type = DT_UINT8;  // Allocate by bytes.
    TensorShape shape({total_size_});
    AllocationAttributes attn;

    out_tensor_ = new Tensor(allocator(), type, shape, attn);

    if (!out_tensor_->IsInitialized()) {
      ResourceExhausted("OOM when allocating tensor with shape", shape.DebugString(), " and type ",
                        "uint8", " on ", allocator_->Name());
    }
    LOG(INFO) << "[TFStorageImpl] shape=" << shape.DebugString() << ", type=uint8"
              << ", size=" << out_tensor_->NumElements() << ", allocator=" << allocator_->Name()
              << ", Gpu BusId=" << bus_id_;

    allocated_ = true;
    ptr_ = (void *)out_tensor_->tensor_data().data();
  }

  Allocator *allocator() {
    if (on_gpu_) {
      gpu_allocator_ =
          GPUProcessState::singleton()->GetGPUAllocator(gpu_option_, gpu_id_, MAX_MEMORY_SIZE, {});
      allocator_ = gpu_allocator_;
      bus_id_ = GPUProcessState::singleton()->BusIdForGPU(gpu_id_);

    } else {
      // CPU Id should be 0 at almost time.
      host_allocator_ = GPUProcessState::singleton()->GetGpuHostAllocator(cpu_id_);
      allocator_ = host_allocator_;
    }
    return allocator_;
  }

  void set_on_gpu(bool on_gpu) { on_gpu_ = on_gpu; }
  void set_gpu_id(int gpu_id) { gpu_id_ = TfDeviceId(gpu_id); }
  void set_cpu_id(int cpu_id) { cpu_id_ = cpu_id; }

  bool on_gpu() { return on_gpu_; }
  int gpu_id() { return gpu_id_.value(); }
  int cpu_id() { return (int)cpu_id_; }

 private:
  bool allocated_;
  bool on_gpu_;

  // Without using `GPUOptions::visible_device_list` in TensorFlow,
  // the device IDs of HCTR are equal to the platform GPU IDs and the
  // TF GPU IDs of TensorFlow. Please refer to here:
  // https://github.com/tensorflow/tensorflow/blob/r2.5/tensorflow/core/common_runtime/device/device_id.h#L70/
  TfDeviceId gpu_id_;

  int cpu_id_;         // refer to tensorflow::GPUProcessState::GetGpuHostAllocator
  size_t total_size_;  // in bytes
  void *ptr_;
  Tensor *out_tensor_;
  Allocator *allocator_;
  Allocator *gpu_allocator_;
  Allocator *host_allocator_;  // A GPU pinned host memory allocator
  GPUOptions gpu_option_;
  int bus_id_;
};

}  // namespace tf_internal