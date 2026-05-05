static const uniform int D = 14;
static const uniform int TOP_C = 16;
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

export void vc_centroid_dists_ispc(
    const uniform int16 query[D],
    const uniform float centroids[],
    uniform int cluster_count,
    uniform float out_dists[]
) {
    foreach (i = 0 ... cluster_count) {
        int base = i * D;
        float dist = 0.0f;

        #pragma unroll
        for (uniform int d = 0; d < D; ++d) {
            float diff = (float)query[d] - centroids[base + d];
            dist += diff * diff;
        }

        out_dists[i] = dist;
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

    uniform int count_base = count & ~(programCount - 1);

    for (uniform int i = 0; i < count_base; i += programCount) {
        int global_idx = start_idx + i + programIndex;
        unsigned int dist = 0u;

        #pragma unroll
        for (uniform int d = 0; d < D; ++d) {
            uniform int dim_base = d * n_vectors;
            int diff = (int)query[d] - (int)dims[dim_base + global_idx];
            unsigned int diff_abs = (unsigned int)abs(diff);
            dist += diff_abs * diff_abs;
        }

        float lane_dist = (float)dist;

        uniform float cutoff = local_top_dist[TOP_C - 1];
        if (any(lane_dist < cutoff)) {
            #pragma unroll
            for (uniform int lane = 0; lane < programCount; ++lane) {
                insert_candidate(local_top_dist, local_top_idx, (uniform unsigned int)(start_idx + i + lane), extract(lane_dist, lane));
            }
        }
    }

    for (uniform int i = count_base; i < count; ++i) {
        uniform unsigned int dist = 0u;

        #pragma unroll
        for (uniform int d = 0; d < D; ++d) {
            uniform int dim_base = d * n_vectors;
            uniform int diff = (uniform int)query[d] - (uniform int)dims[dim_base + start_idx + i];
            uniform unsigned int diff_abs = (uniform unsigned int)abs(diff);
            dist += diff_abs * diff_abs;
        }

        insert_candidate(local_top_dist, local_top_idx, (uniform unsigned int)(start_idx + i), (uniform float)dist);
    }

    uniform int out_count = min(count, TOP_C);

    #pragma unroll
    for (uniform int k = 0; k < TOP_C; ++k) {
        if (k < out_count) {
            out_idx[k] = local_top_idx[k];
            out_dists[k] = local_top_dist[k];
        }
    }
}
