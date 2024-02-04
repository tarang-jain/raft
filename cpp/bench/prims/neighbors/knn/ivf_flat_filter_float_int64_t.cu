/*
 * Copyright (c) 2023, NVIDIA CORPORATION.
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

#undef RAFT_EXPLICIT_INSTANTIATE_ONLY  // Enable instantiation of search with filter
#include "../knn.cuh"

namespace raft::bench::spatial {

KNN_REGISTER(float, int64_t, ivf_flat_filter_knn, kInputsFilter, kNoCopyOnly, kScopeFull);

}  // namespace raft::bench::spatial
