/*
 * Copyright (c) 2022-2023, NVIDIA CORPORATION.
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
#include <raft/core/error.hpp>
#include <string>

namespace raft {
#ifndef RAFT_DISABLE_GPU
auto constexpr static const CUDA_ENABLED = true;
#else
auto constexpr static const CUDA_ENABLED    = false;
#endif

#ifdef __CUDACC__
#define HOST   __host__
#define DEVICE __device__
auto constexpr static const GPU_COMPILATION = true;
#else
#define HOST
#define DEVICE
auto constexpr static const GPU_COMPILATION = false;
#endif

#ifndef DEBUG
auto constexpr static const DEBUG_ENABLED = false;
#elif DEBUG == 0
auto constexpr static const DEBUG_ENABLED   = false;
#else
auto constexpr static const DEBUG_ENABLED = true;
#endif

struct cuda_unsupported : raft::exception {
  explicit cuda_unsupported(std::string const& msg) : raft::exception{msg} {}
  cuda_unsupported() : cuda_unsupported{"CUDA functionality invoked in non-CUDA build"} {}
};

}  // namespace raft