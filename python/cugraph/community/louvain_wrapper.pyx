# Copyright (c) 2019-2020, NVIDIA CORPORATION.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# cython: profile=False
# distutils: language = c++
# cython: embedsignature = True
# cython: language_level = 3

from cugraph.community cimport louvain as c_louvain
from cugraph.structure.graph_primtypes cimport *
from cugraph.structure import graph_primtypes_wrapper
from libc.stdint cimport uintptr_t

import cudf
import rmm
import numpy as np


def louvain(input_graph, max_level, resolution):
    """
    Call louvain
    """
    if not input_graph.adjlist:
        input_graph.view_adj_list()

    cdef unique_ptr[handle_t] handle_ptr
    handle_ptr.reset(new handle_t())
    handle_ = handle_ptr.get();

    weights = None
    final_modularity = None

    [offsets, indices] = graph_primtypes_wrapper.datatype_cast([input_graph.adjlist.offsets, input_graph.adjlist.indices], [np.int32])

    num_verts = input_graph.number_of_vertices()
    num_edges = input_graph.number_of_edges(directed_edges=True)

    if input_graph.adjlist.weights is not None:
        [weights] = graph_primtypes_wrapper.datatype_cast([input_graph.adjlist.weights], [np.float32, np.float64])
    else:
        weights = cudf.Series(np.full(num_edges, 1.0, dtype=np.float32))

    # Create the output dataframe
    df = cudf.DataFrame()
    df['vertex'] = cudf.Series(np.zeros(num_verts, dtype=np.int32))
    df['partition'] = cudf.Series(np.zeros(num_verts,dtype=np.int32))

    cdef uintptr_t c_offsets = offsets.__cuda_array_interface__['data'][0]
    cdef uintptr_t c_indices = indices.__cuda_array_interface__['data'][0]
    cdef uintptr_t c_identifier = df['vertex'].__cuda_array_interface__['data'][0]
    cdef uintptr_t c_partition = df['partition'].__cuda_array_interface__['data'][0]
    cdef uintptr_t c_weights = weights.__cuda_array_interface__['data'][0]
    cdef uintptr_t c_local_verts = <uintptr_t> NULL;
    cdef uintptr_t c_local_edges = <uintptr_t> NULL;
    cdef uintptr_t c_local_offsets = <uintptr_t> NULL;


    cdef float final_modularity_float = 1.0
    cdef double final_modularity_double = 1.0
    cdef int num_level = 0

    # FIXME: Offsets and indices are currently hardcoded to int, but this may
    #        not be acceptable in the future.
    weightTypeMap = {np.dtype("float32") : <int>numberTypeEnum.floatType,
                     np.dtype("double") : <int>numberTypeEnum.doubleType}

    cdef graph_container_t graph_container

    # FIXME: The excessive casting for the enum arg is needed to make cython
    #        understand how to pass the enum value (this is the same pattern
    #        used by cudf). This will not be needed with Cython 3.0
    populate_graph_container(graph_container,
                             <legacyGraphTypeEnum>(<int>(legacyGraphTypeEnum.CSR)),
                             handle_[0],
                             <void*>c_offsets, <void*>c_indices, <void*>c_weights,
                             <numberTypeEnum>(<int>(numberTypeEnum.intType)),
                             <numberTypeEnum>(<int>(numberTypeEnum.intType)),
                             <numberTypeEnum>(<int>(weightTypeMap[weights.dtype])),
                             num_verts, num_edges,
                             <int*>c_local_verts, <int*>c_local_edges, <int*>c_local_offsets,
                             False, True)  # store_transposed, multi_gpu

    graph_container.get_vertex_identifiers(<void*>c_identifier)

    if weights.dtype == np.float32:
        num_level, final_modularity_float = c_louvain.call_louvain[float](handle_[0], graph_container,
                                                      <void*> c_partition,
                                                      max_level,
                                                      resolution)

        final_modularity = final_modularity_float
    else:
        num_level, final_modularity_double = c_louvain.call_louvain[double](handle_[0], graph_container,
                                                                            <void*> c_partition,
                                                                            max_level,
                                                                            resolution)
        final_modularity = final_modularity_double

    return df, final_modularity
