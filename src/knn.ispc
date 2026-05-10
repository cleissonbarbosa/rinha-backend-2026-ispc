static const uniform int D = 14;
static const uniform int TOP_C = 16;
static const uniform int TOP_PROBE = 24;
static const uniform float INF_F32 = 3.402823466e+38f;

static inline void insert_candidate(
    uniform float top_dist[TOP_C],
    uniform unsigned int top_idx[TOP_C],
    uniform unsigned int idx,
    uniform float dist
) {
    if (dist < top_dist[TOP_C - 1]) {
        uniform int pos = TOP_C - 1;
        while (pos > 0 && top_dist[pos - 1] > dist) {
            top_dist[pos] = top_dist[pos - 1];
            top_idx[pos] = top_idx[pos - 1];
            --pos;
        }
        top_dist[pos] = dist;
        top_idx[pos] = idx;
    }
}

static inline void insert_probe_candidate(
    uniform float top_dist[TOP_PROBE],
    uniform unsigned int top_idx[TOP_PROBE],
    uniform int limit,
    uniform unsigned int idx,
    uniform float dist
) {
    if (dist < top_dist[limit - 1]) {
        uniform int pos = limit - 1;
        while (pos > 0 && top_dist[pos - 1] > dist) {
            top_dist[pos] = top_dist[pos - 1];
            top_idx[pos] = top_idx[pos - 1];
            --pos;
        }
        top_dist[pos] = dist;
        top_idx[pos] = idx;
    }
}

static inline uniform int scan_one_range_top(
    uniform float local_top_dist[TOP_C],
    uniform unsigned int local_top_idx[TOP_C],
    const uniform int16 query[D],
    const uniform int16 dims[],
    uniform int n_vectors,
    uniform int start_idx,
    uniform int count
) {
    uniform int count_base = count & ~(programCount - 1);

    for (uniform int i = 0; i < count_base; i += programCount) {
        int local_i = i + programIndex;
        int global_idx = start_idx + local_i;
        float dist = 0.0f;

        #pragma unroll
        for (uniform int d = 0; d < D; ++d) {
            uniform int dim_base = d * n_vectors;
            int diff_i = (int)query[d] - (int)dims[dim_base + global_idx];
            float diff = (float)diff_i;
            dist += diff * diff;
        }

        uniform float cutoff = local_top_dist[TOP_C - 1];
        if (any(dist < cutoff)) {
            #pragma unroll
            for (uniform int lane = 0; lane < programCount; ++lane) {
                insert_candidate(
                    local_top_dist,
                    local_top_idx,
                    (uniform unsigned int)(start_idx + i + lane),
                    extract(dist, lane)
                );
            }
        }
    }

    for (uniform int i = count_base; i < count; ++i) {
        uniform float dist = 0.0f;

        #pragma unroll
        for (uniform int d = 0; d < D; ++d) {
            uniform int dim_base = d * n_vectors;
            uniform int diff_i = (uniform int)query[d] - (uniform int)dims[dim_base + start_idx + i];
            uniform float diff = (uniform float)diff_i;
            dist += diff * diff;
        }

        insert_candidate(local_top_dist, local_top_idx, (uniform unsigned int)(start_idx + i), dist);
    }

    return min(count, TOP_C);
}

export void vc_dists_q16_ispc(
    const uniform int16 query[D],
    const uniform int16 dims[],
    uniform int n_vectors,
    uniform int start_idx,
    uniform int count,
    uniform float out_dists[]
) {
    {
        uniform int dim_base = start_idx;
        uniform int q0 = (uniform int)query[0];
        foreach (i = 0 ... count) {
            int diff = q0 - (int)dims[dim_base + i];
            out_dists[i] = (float)(diff * diff);
        }
    }

    #pragma unroll
    for (uniform int d = 1; d < D; ++d) {
        uniform int dim_base = d * n_vectors + start_idx;
        uniform int qd = (uniform int)query[d];
        foreach (i = 0 ... count) {
            int diff = qd - (int)dims[dim_base + i];
            out_dists[i] = out_dists[i] + (float)(diff * diff);
        }
    }
}

export void vc_scan_top_q16_ispc(
    const uniform int16 query[D],
    const uniform int16 dims[],
    uniform int n_vectors,
    uniform int start_idx,
    uniform int count,
    uniform unsigned int out_idx[],
    uniform float out_dists[]
) {
    uniform float local_top_dist[TOP_C];
    uniform unsigned int local_top_idx[TOP_C];

    #pragma unroll
    for (uniform int k = 0; k < TOP_C; ++k) {
        local_top_dist[k] = INF_F32;
        local_top_idx[k] = 0u;
    }

    uniform int out_count = scan_one_range_top(
        local_top_dist,
        local_top_idx,
        query,
        dims,
        n_vectors,
        start_idx,
        count
    );

    #pragma unroll
    for (uniform int k = 0; k < TOP_C; ++k) {
        if (k < out_count) {
            out_idx[k] = local_top_idx[k];
            out_dists[k] = local_top_dist[k];
        }
    }
}

export void vc_scan_ranges_top_q16_ispc(
    const uniform int16 query[D],
    const uniform int16 dims[],
    uniform int n_vectors,
    const uniform unsigned int starts[],
    const uniform unsigned int ends[],
    uniform int range_count,
    uniform unsigned int out_idx[],
    uniform float out_dists[]
) {
    uniform float local_top_dist[TOP_C];
    uniform unsigned int local_top_idx[TOP_C];
    uniform int total = 0;

    #pragma unroll
    for (uniform int k = 0; k < TOP_C; ++k) {
        local_top_dist[k] = INF_F32;
        local_top_idx[k] = 0u;
    }

    for (uniform int r = 0; r < range_count; ++r) {
        uniform int start_idx = (uniform int)starts[r];
        uniform int end_idx = (uniform int)ends[r];
        uniform int count = end_idx - start_idx;
        if (count <= 0) {
            continue;
        }
        total += count;
        scan_one_range_top(
            local_top_dist,
            local_top_idx,
            query,
            dims,
            n_vectors,
            start_idx,
            count
        );
    }

    uniform int out_count = min(total, TOP_C);
    #pragma unroll
    for (uniform int k = 0; k < TOP_C; ++k) {
        if (k < out_count) {
            out_idx[k] = local_top_idx[k];
            out_dists[k] = local_top_dist[k];
        }
    }
}

export void vc_centroid_dists_soa_ispc(
    const uniform int16 query[D],
    const uniform float centroids_soa[],
    uniform int n_padded,
    uniform float out_dists[]
) {
    {
        uniform int row_base = 0;
        uniform float q0 = (uniform float)query[0];
        foreach (c = 0 ... n_padded) {
            float diff = q0 - centroids_soa[row_base + c];
            out_dists[c] = diff * diff;
        }
    }

    #pragma unroll
    for (uniform int d = 1; d < D; ++d) {
        uniform int row_base = d * n_padded;
        uniform float qd = (uniform float)query[d];
        foreach (c = 0 ... n_padded) {
            float diff = qd - centroids_soa[row_base + c];
            out_dists[c] = out_dists[c] + diff * diff;
        }
    }
}

export void vc_centroid_dists_top_soa_ispc(
    const uniform int16 query[D],
    const uniform float centroids_soa[],
    uniform int n_padded,
    uniform int probe_count,
    uniform float out_dists[],
    uniform unsigned int out_idx[],
    uniform float out_probe_dists[]
) {
    uniform float local_top_dist[TOP_PROBE];
    uniform unsigned int local_top_idx[TOP_PROBE];

    #pragma unroll
    for (uniform int k = 0; k < TOP_PROBE; ++k) {
        local_top_dist[k] = INF_F32;
        local_top_idx[k] = 0u;
    }

    foreach (c = 0 ... n_padded) {
        float diff0 = (uniform float)query[0] - centroids_soa[c];
        float dist = diff0 * diff0;

        #pragma unroll
        for (uniform int d = 1; d < D; ++d) {
            uniform int row_base = d * n_padded;
            float diff = (uniform float)query[d] - centroids_soa[row_base + c];
            dist += diff * diff;
        }

        out_dists[c] = dist;
        uniform float cutoff = local_top_dist[probe_count - 1];
        if (any(dist < cutoff)) {
            #pragma unroll
            for (uniform int lane = 0; lane < programCount; ++lane) {
                insert_probe_candidate(
                    local_top_dist,
                    local_top_idx,
                    probe_count,
                    (uniform unsigned int)extract(c, lane),
                    extract(dist, lane)
                );
            }
        }
    }

    #pragma unroll
    for (uniform int k = 0; k < TOP_PROBE; ++k) {
        if (k < probe_count) {
            out_idx[k] = local_top_idx[k];
            out_probe_dists[k] = local_top_dist[k];
        }
    }
}
