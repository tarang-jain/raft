/*
 * Copyright (c) 2018-2023, NVIDIA CORPORATION.
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

#include <cub/cub.cuh>

#include <raft/distance/distance_types.hpp>
#include <raft/distance/masked_nn.cuh>
#include <raft/label/classlabels.cuh>
#include <raft/linalg/norm.cuh>
#include <raft/sparse/convert/csr.cuh>
#include <raft/sparse/coo.hpp>
#include <raft/sparse/linalg/symmetrize.cuh>
#include <raft/sparse/op/reduce.cuh>

#include <raft/util/cudart_utils.hpp>
#include <raft/util/fast_int_div.cuh>
#include <rmm/device_uvector.hpp>
#include <rmm/exec_policy.hpp>

#include <raft/core/kvp.hpp>
#include <thrust/copy.h>
#include <thrust/device_ptr.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/iterator/zip_iterator.h>
#include <thrust/scan.h>
#include <thrust/sort.h>
#include <thrust/transform.h>
#include <thrust/tuple.h>

#include <cub/cub.cuh>

#include <limits>

namespace raft::sparse::neighbors::detail {

/**
 * Functor with reduction ops for performing fused 1-nn
 * computation and guaranteeing only cross-component
 * neighbors are considered.
 * @tparam value_idx
 * @tparam value_t
 */
template <typename value_idx, typename value_t>
struct FixConnectivitiesRedOp {
  value_idx m;

  FixConnectivitiesRedOp(value_idx m_) : m(m_){};

  typedef typename raft::KeyValuePair<value_idx, value_t> KVP;
  DI void operator()(value_idx rit, KVP* out, const KVP& other)
  {
    if (rit < m && other.value < out->value) {
      out->key   = other.key;
      out->value = other.value;
    }
  }

  DI KVP

  operator()(value_idx rit, const KVP& a, const KVP& b)
  {
    if (rit < m && a.value < b.value) {
      return a;
    } else
      return b;
  }

  DI void init(value_t* out, value_t maxVal) { *out = maxVal; }
  DI void init(KVP* out, value_t maxVal)
  {
    out->key   = -1;
    out->value = maxVal;
  }
};

/**
 * Assumes 3-iterator tuple containing COO rows, cols, and
 * a cub keyvalue pair object. Sorts the 3 arrays in
 * ascending order: row->col->keyvaluepair
 */
struct TupleComp {
  template <typename one, typename two>
  __host__ __device__ bool operator()(const one& t1, const two& t2)
  {
    // sort first by each sample's color,
    if (thrust::get<0>(t1) < thrust::get<0>(t2)) return true;
    if (thrust::get<0>(t1) > thrust::get<0>(t2)) return false;

    // then by the color of each sample's closest neighbor,
    if (thrust::get<1>(t1) < thrust::get<1>(t2)) return true;
    if (thrust::get<1>(t1) > thrust::get<1>(t2)) return false;

    // then sort by value in descending order
    return thrust::get<2>(t1).value < thrust::get<2>(t2).value;
  }
};

template <typename LabelT, typename DataT>
struct CubKVPMinReduce {
  typedef raft::KeyValuePair<LabelT, DataT> KVP;

  DI KVP

  operator()(LabelT rit, const KVP& a, const KVP& b)
  {
    return b.value < a.value ? b : a;
  }

  DI KVP

  operator()(const KVP& a, const KVP& b)
  {
    return b.value < a.value ? b : a;
  }

};  // KVPMinReduce

/**
 * Gets the number of unique components from array of
 * colors or labels. This does not assume the components are
 * drawn from a monotonically increasing set.
 * @tparam value_idx
 * @param[in] colors array of components
 * @param[in] n_rows size of components array
 * @param[in] stream cuda stream for which to order cuda operations
 * @return total number of components
 */
template <typename value_idx>
value_idx get_n_components(value_idx* colors, size_t n_rows, cudaStream_t stream)
{
  rmm::device_uvector<value_idx> map_ids(0, stream);
  int num_clusters = raft::label::getUniquelabels(map_ids, colors, n_rows, stream);
  return num_clusters;
}

/**
 * Functor to look up a component for a vertex
 * @tparam value_idx
 * @tparam value_t
 */
template <typename value_idx, typename value_t>
struct LookupColorOp {
  value_idx* colors;

  LookupColorOp(value_idx* colors_) : colors(colors_) {}

  DI value_idx

  operator()(const raft::KeyValuePair<value_idx, value_t>& kvp)
  {
    return colors[kvp.key];
  }
};

template <typename value_idx, typename value_t>
__global__ void copy_sorted_kernel(const value_t* X,
                                   value_t* X_cpy,
                                   value_idx* src_indices,
                                   size_t n_rows,
                                   raft::util::FastIntDiv n_cols)
{
  value_idx tid = blockDim.x * blockIdx.x + threadIdx.x;
  if (tid >= n_rows * n_cols.d) return;
  value_idx row = tid / n_cols;
  value_idx col = tid % n_cols;
  X_cpy[tid] = X[src_indices[row] * n_cols.d + col];
}

/**
 * Compute the cross-component 1-nearest neighbors for each row in X using
 * the given array of components
 * @tparam value_idx
 * @tparam value_t
 * @param[out] kvp mapping of closest neighbor vertex and distance for each vertex in the given
 * array of components
 * @param[out] nn_colors components of nearest neighbors for each vertex
 * @param[in] colors components of each vertex
 * @param[in] X original dense data
 * @param[in] n_rows number of rows in original dense data
 * @param[in] n_cols number of columns in original dense data
 * @param[in] stream cuda stream for which to order cuda operations
 */
template <typename value_idx, typename value_t, typename red_op>
void perform_1nn(raft::device_resources const& handle,
                 raft::KeyValuePair<value_idx, value_t>* kvp,
                 value_idx* nn_colors,
                 value_idx* colors,
                 value_idx* src_indices,
                 const value_t* X,
                 size_t n_rows,
                 size_t n_cols,
                 red_op reduction_op)
{
  auto stream = handle.get_stream();

  // raft::print_device_vector("colors_before_sort", colors, n_rows, std::cout);
  // raft::print_device_vector("X_before_sort", X, 50, std::cout);
  // raft::print_device_vector("src_indices_before_sort", src_indices, n_rows, std::cout);
  // Sort data points by color
  // thrust::sort_by_key(handle.get_thrust_policy(), colors, colors + n_rows, thrust::make_zip_iterator(thrust::make_tuple(src_indices)));

  // auto X_cpy = raft::make_device_matrix<value_t, value_idx>(handle, n_rows, n_cols);
  // copy_sorted_kernel<<<raft::ceildiv(n_rows * n_cols, (size_t)256), 256, 0, stream>>>(X,
  //                                  X_cpy.data_handle(),
  //                                  src_indices,
  //                                  n_rows,
  //                                  raft::util::FastIntDiv(n_cols));
  // raft::print_device_vector("colors_after_sort", colors, n_rows, std::cout);
  // raft::print_device_vector("X_after_sort", X_cpy.data_handle(), 50, std::cout);
  // raft::print_device_vector("src_indices_after_sort", src_indices, n_rows, std::cout);
  auto x_norm = raft::make_device_vector<value_t, value_idx>(handle, n_rows);

  raft::linalg::rowNorm(x_norm.data_handle(), X, n_cols, n_rows, raft::linalg::L2Norm, true, stream);

    value_idx n_components = get_n_components(colors, n_rows, stream);
    auto colors_group_idxs = raft::make_device_vector<value_idx, value_idx> (handle, n_components + 1);
    raft::sparse::convert::sorted_coo_to_csr(colors, n_rows, colors_group_idxs.data_handle(), n_components + 1, stream);

    raft::print_device_vector("colors", colors, n_rows, std::cout);
    raft::print_device_vector("colors_csr", colors_group_idxs.data_handle(), n_components + 1, std::cout);
    auto adj = raft::make_device_matrix<bool, value_idx> (handle, n_rows, n_components);
    auto adj_iterator = thrust::make_counting_iterator<value_idx>(0);
    auto mask_op = [colors, n_components = raft::util::FastIntDiv(n_components), adj = adj.data_handle()] __device__(value_idx idx) {
      value_idx row = idx / n_components;
      value_idx col = idx % n_components;
      return colors[row] != col;
    };
    thrust::transform(handle.get_thrust_policy(),
                      adj_iterator,
                      adj_iterator + n_rows * n_components,
                      adj.data_handle(),
                      mask_op);
    handle.sync_stream(stream);
    raft::print_device_vector("adj", adj.data_handle(), 30, std::cout);
    // auto adj_view = raft::make_device_matrix_view<const bool, value_idx>(adj.data(), n_rows, n_components);
    auto kvp_view = raft::make_device_vector_view<raft::KeyValuePair<value_idx, value_t>, value_idx>(kvp, n_rows);
  using OutT       = raft::KeyValuePair<value_idx, value_t>;
  // using RedOpT     = raft::distance::MinAndDistanceReduceOp<int, DataT>;
  // using PairRedOpT = raft::distance::KVPMinReduce<int, DataT>;
  using ParamT     = raft::distance::masked_l2_nn_params<red_op, red_op>;
  // raft::distance::initialize<value_t, raft::KeyValuePair<int, value_t>, int>(
  //     handle, kvp, n_rows, std::numeric_limits<value_t>::max(), RedOpT{});
    ParamT params{
        reduction_op,
        reduction_op,
        true,
        true};
    raft::distance::masked_l2_nn<value_t, OutT, value_idx, red_op, red_op>(handle,
                  params,
                  X,
                  X,
             x_norm.view(),
                x_norm.view(),
                  adj.view(),
                  raft::make_device_vector_view(colors_group_idxs.data_handle() + 1, n_components),
                  kvp_view);

  handle.sync_stream(stream);
  RAFT_LOG_INFO("Done until masked l2 distance");
  LookupColorOp<value_idx, value_t> extract_colors_op(colors);
  thrust::transform(rmm::exec_policy(stream), kvp, kvp + n_rows, nn_colors, extract_colors_op);

  raft::print_device_vector("nn_colors", nn_colors, n_rows, std::cout);
  auto fetch_neighbor_indices_op = [kvp, src_indices]__device__ (auto t) {
    thrust::get<0>(t).key = src_indices[thrust::get<0>(t).key];
  };
  auto kvp_iterator = thrust::make_zip_iterator(thrust::make_tuple(kvp));
  rmm::device_uvector<value_idx> nbrs(n_rows, stream);
  rmm::device_uvector<value_t> dists(n_rows, stream);

  auto nbrs_it = thrust::make_zip_iterator(thrust::make_tuple(kvp, nbrs.data(), dists.data()));
  thrust::for_each(handle.get_thrust_policy(), nbrs_it, nbrs_it + n_rows, [=]__device__ (auto t) {
    thrust::get<1>(t) = thrust::get<0>(t).key;
    thrust::get<2>(t) = thrust::get<0>(t).value;
  });
  handle.sync_stream(stream);
  raft::print_device_vector("nbrs_original", nbrs.data(), n_rows, std::cout);
  raft::print_device_vector("nbrs_dists", dists.data(), n_rows, std::cout);

  thrust::for_each(rmm::exec_policy(stream), kvp_iterator, kvp_iterator + n_rows, fetch_neighbor_indices_op);

  handle.sync_stream(stream);
  RAFT_LOG_INFO("Done until fetching neighbor indices");
}

/**
 * Sort nearest neighboring components wrt component of source vertices
 * @tparam value_idx
 * @tparam value_t
 * @param[inout] colors components array of source vertices
 * @param[inout] nn_colors nearest neighbors components array
 * @param[inout] kvp nearest neighbor source vertex / distance array
 * @param[inout] src_indices array of source vertex indices which will become arg_sort
 *               indices
 * @param n_rows number of components in `colors`
 * @param stream stream for which to order CUDA operations
 */
template <typename value_idx, typename value_t>
void sort_by_color(value_idx* colors,
                   value_idx* nn_colors,
                   raft::KeyValuePair<value_idx, value_t>* kvp,
                   value_idx* src_indices,
                   size_t n_rows,
                   cudaStream_t stream)
{
  thrust::counting_iterator<value_idx> arg_sort_iter(0);
  thrust::copy(rmm::exec_policy(stream), arg_sort_iter, arg_sort_iter + n_rows, src_indices);

  auto keys = thrust::make_zip_iterator(
    thrust::make_tuple(colors, nn_colors, (KeyValuePair<value_idx, value_t>*)kvp));
  auto vals = thrust::make_zip_iterator(thrust::make_tuple(src_indices));
  // get all the colors in contiguous locations so we can map them to warps.
  thrust::sort_by_key(rmm::exec_policy(stream), keys, keys + n_rows, vals, TupleComp());
}

template <typename value_idx, typename value_t>
__global__ void min_components_by_color_kernel(value_idx* out_rows,
                                               value_idx* out_cols,
                                               value_t* out_vals,
                                               const value_idx* out_index,
                                               const value_idx* indices,
                                               const raft::KeyValuePair<value_idx, value_t>* kvp,
                                               size_t nnz)
{
  size_t tid = blockDim.x * blockIdx.x + threadIdx.x;

  if (tid >= nnz) return;

  int idx = out_index[tid];

  if ((tid == 0 || (out_index[tid - 1] != idx))) {
    out_rows[idx] = indices[tid];
    out_cols[idx] = kvp[tid].key;
    out_vals[idx] = kvp[tid].value;
  }
}

/**
 * Computes the min set of unique components that neighbor the
 * components of each source vertex.
 * @tparam value_idx
 * @tparam value_t
 * @param[out] coo output edge list
 * @param[in] out_indptr output indptr for ordering edge list
 * @param[in] colors_indptr indptr of source components
 * @param[in] colors_nn components of nearest neighbors to each source component
 * @param[in] indices indices of source vertices for each component
 * @param[in] kvp indices and distances of each destination vertex for each component
 * @param[in] n_colors number of components
 * @param[in] stream cuda stream for which to order cuda operations
 */
template <typename value_idx, typename value_t>
void min_components_by_color(raft::sparse::COO<value_t, value_idx>& coo,
                             const value_idx* out_index,
                             const value_idx* indices,
                             const raft::KeyValuePair<value_idx, value_t>* kvp,
                             size_t nnz,
                             cudaStream_t stream)
{
  /**
   * Arrays should be ordered by: colors_indptr->colors_n->kvp.value
   * so the last element of each column in the input CSR should be
   * the min.
   */
  min_components_by_color_kernel<<<raft::ceildiv(nnz, (size_t)256), 256, 0, stream>>>(
    coo.rows(), coo.cols(), coo.vals(), out_index, indices, kvp, nnz);
}

/**
 * Connects the components of an otherwise unconnected knn graph
 * by computing a 1-nn to neighboring components of each data point
 * (e.g. component(nn) != component(self)) and reducing the results to
 * include the set of smallest destination components for each source
 * component. The result will not necessarily contain
 * n_components^2 - n_components number of elements because many components
 * will likely not be contained in the neighborhoods of 1-nns.
 * @tparam value_idx
 * @tparam value_t
 * @param[in] handle raft handle
 * @param[out] out output edge list containing nearest cross-component
 *             edges.
 * @param[in] X original (row-major) dense matrix for which knn graph should be constructed.
 * @param[in] colors array containing component number for each row of X
 * @param[in] n_rows number of rows in X
 * @param[in] n_cols number of cols in X
 */
template <typename value_idx, typename value_t, typename red_op>
void connect_components(
  raft::device_resources const& handle,
  raft::sparse::COO<value_t, value_idx>& out,
  const value_t* X,
  const value_idx* orig_colors,
  size_t n_rows,
  size_t n_cols,
  red_op reduction_op,
  raft::distance::DistanceType metric = raft::distance::DistanceType::L2SqrtExpanded)
{
  auto stream = handle.get_stream();

  RAFT_EXPECTS(metric == raft::distance::DistanceType::L2SqrtExpanded,
               "Fixing connectivities for an unconnected k-NN graph only "
               "supports L2SqrtExpanded currently.");

  rmm::device_uvector<value_idx> colors(n_rows, stream);
  raft::copy_async(colors.data(), orig_colors, n_rows, stream);

  // Normalize colors so they are drawn from a monotonically increasing set
  raft::label::make_monotonic(colors.data(), colors.data(), n_rows, stream, true);

  /**
   * First compute 1-nn for all colors where the color of each data point
   * is guaranteed to be != color of its nearest neighbor.
   */
  rmm::device_uvector<value_idx> nn_colors(n_rows, stream);
  rmm::device_uvector<raft::KeyValuePair<value_idx, value_t>> temp_inds_dists(n_rows, stream);
  rmm::device_uvector<value_idx> src_indices(n_rows, stream);

  perform_1nn(handle,
               temp_inds_dists.data(),
               nn_colors.data(),
              colors.data(),
               src_indices,
               X,
               n_rows,
               n_cols,
               reduction_op);

  /**
   * Sort data points by color (neighbors are not sorted)
   */
  // max_color + 1 = number of connected components
  // sort nn_colors by key w/ original colors
  sort_by_color(
    colors.data(), nn_colors.data(), temp_inds_dists.data(), src_indices.data(), n_rows, stream);

  /**
   * Take the min for any duplicate colors
   */
  // Compute mask of duplicates
  rmm::device_uvector<value_idx> out_index(n_rows + 1, stream);
  raft::sparse::op::compute_duplicates_mask(
    out_index.data(), colors.data(), nn_colors.data(), n_rows, stream);

    raft::print_device_vector("colors", colors.data(), n_rows, std::cout);
    raft::print_device_vector("nn_colors", nn_colors.data(), n_rows, std::cout);
    raft::print_device_vector("out_index", out_index.data(), n_rows, std::cout);

  thrust::exclusive_scan(handle.get_thrust_policy(),
                         out_index.data(),
                         out_index.data() + out_index.size(),
                         out_index.data());
  raft::print_device_vector("out_index", out_index.data(), n_rows, std::cout);

  // compute final size
  value_idx size = 0;
  raft::update_host(&size, out_index.data() + (out_index.size() - 1), 1, stream);
  handle.sync_stream(stream);

  size++;

  raft::sparse::COO<value_t, value_idx> min_edges(stream);
  min_edges.allocate(size, n_rows, n_rows, true, stream);

  min_components_by_color(
    min_edges, out_index.data(), src_indices.data(), temp_inds_dists.data(), n_rows, stream);

  /**
   * Symmetrize resulting edge list
   */
  raft::sparse::linalg::symmetrize(
    handle, min_edges.rows(), min_edges.cols(), min_edges.vals(), n_rows, n_rows, size, out);
}

};  // end namespace raft::sparse::neighbors::detail
