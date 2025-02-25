// Copyright Supranational LLC
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

template<unsigned int z_count>
__launch_bounds__(768, 1) __global__
void _GS_NTT(const unsigned int radix, const unsigned int lg_domain_size,
             const unsigned int stage, const unsigned int iterations,
             fr_t* d_inout, const fr_t (*d_partial_twiddles)[WINDOW_SIZE],
             const fr_t* d_radix6_twiddles, const fr_t* d_radixX_twiddles,
             bool is_intt, const fr_t d_domain_size_inverse)
{
#if (__CUDACC_VER_MAJOR__-0) >= 11
    __builtin_assume(lg_domain_size <= MAX_LG_DOMAIN_SIZE);
    __builtin_assume(radix <= 10);
    __builtin_assume(iterations <= radix);
    __builtin_assume(stage <= lg_domain_size && stage >= iterations);
#endif
    extern __shared__ fr_t shared_exchange[];

    index_t tid = threadIdx.x + blockDim.x * (index_t)blockIdx.x;

    const index_t diff_mask = (1 << (iterations - 1)) - 1;
    const index_t inp_ntt_size = (index_t)1 << (stage - 1);

    const index_t tiz = (tid & ~diff_mask) * z_count + (tid & diff_mask);

    index_t idx[2][z_count];
    fr_t r[2][z_count];

    #pragma unroll
    for (int z = 0; z < z_count; z++) {
        index_t tid = tiz + (z << (iterations - 1));

        // rearrange |tid|'s bits
        idx[0][z] = (tid & ~(inp_ntt_size - 1)) * 2;
        idx[0][z] += (tid << (stage - iterations)) & (inp_ntt_size - 1);
        idx[0][z] += tid >> (iterations - 1);
        idx[0][z] -= (tid >> (stage - 1)) << (stage - iterations);
        idx[1][z] = idx[0][z] + inp_ntt_size;

        r[0][z] = d_inout[idx[0][z]];
        r[1][z] = d_inout[idx[1][z]];
    }

    #pragma unroll 1
    for (int s = iterations; --s >= 6;) {
        unsigned int laneMask = 1 << (s - 1);
        unsigned int thrdMask = (1 << s) - 1;
        unsigned int rank = threadIdx.x & thrdMask;
        bool pos = rank < laneMask;

        fr_t root = d_radixX_twiddles[rank << (radix - (s + 1))];

        #pragma unroll
        for (int z = 0; z < z_count; z++) {
            fr_t t = root * (r[0][z] - r[1][z]);
            r[0][z] = r[0][z] + r[1][z];
            r[1][z] = t;
        }

        __syncthreads();

        fr_t (*xchg)[z_count] = reinterpret_cast<decltype(xchg)>(shared_exchange);
#ifdef __CUDA_ARCH__
        #pragma unroll
        for (int z = 0; z < z_count; z++) {
            fr_t t = fr_t::csel(r[1][z], r[0][z], pos);
            xchg[threadIdx.x][z] = t;
        }

        __syncthreads();

        #pragma unroll
        for (int z = 0; z < z_count; z++) {
            fr_t t = xchg[threadIdx.x ^ laneMask][z];
            r[0][z] = fr_t::csel(t, r[0][z], !pos);
            r[1][z] = fr_t::csel(t, r[1][z], pos);
        }

        __syncthreads();
#endif

        index_t (*xchgi)[z_count] = reinterpret_cast<decltype(xchgi)>(shared_exchange);
        #pragma unroll
        for (int z = 0; z < z_count; z++) {
            if (pos)
                swap(idx[0][z], idx[1][z]);

            xchgi[threadIdx.x][z] = idx[0][z];
        }

        __syncthreads();

        #pragma unroll
        for (int z = 0; z < z_count; z++) {
            idx[0][z] = xchgi[threadIdx.x ^ laneMask][z];

            if (pos)
                swap(idx[0][z], idx[1][z]);
        }
    }

    #pragma unroll 1
    for (int s = min(iterations, 6); --s >= 1;) {
        unsigned int laneMask = 1 << (s - 1);
        unsigned int thrdMask = (1 << s) - 1;
        unsigned int rank = threadIdx.x & thrdMask;
        bool pos = rank < laneMask;

        fr_t root = d_radix6_twiddles[rank << (6 - (s + 1))];

        #pragma unroll
        for (int z = 0; z < z_count; z++) {
            fr_t t = root * (r[0][z] - r[1][z]);
            r[0][z] = r[0][z] + r[1][z];
            r[1][z] = t;

#ifdef __CUDA_ARCH__
            t = fr_t::csel(r[1][z], r[0][z], pos);
            if (pos)
                swap(idx[0][z], idx[1][z]);

            shfl_bfly(t, laneMask);
            shfl_bfly(idx[0][z], laneMask);

            r[0][z] = fr_t::csel(t, r[0][z], !pos);
            r[1][z] = fr_t::csel(t, r[1][z], pos);
            if (pos)
                swap(idx[0][z], idx[1][z]);
#endif
        }
    }

    #pragma unroll
    for (int z = 0; z < z_count; z++) {
        fr_t t = r[0][z] - r[1][z];
        r[0][z] = r[0][z] + r[1][z];
        r[1][z] = t;
    }

    if (stage - iterations != 0) {
        index_t thread_ntt_pos = (tiz & (inp_ntt_size - 1)) >> (iterations - 1);
        unsigned int thread_ntt_idx = (tiz & diff_mask) * 2;
        unsigned int nbits = MAX_LG_DOMAIN_SIZE - (stage - iterations);
        index_t idx0 = bit_rev(thread_ntt_idx, nbits);
        index_t root_idx0 = idx0 * thread_ntt_pos;
        index_t root_idx1 = root_idx0 + (thread_ntt_pos << (nbits - 1));

        fr_t first_root, second_root;
        get_intermediate_roots(first_root, second_root,
                               root_idx0, root_idx1, d_partial_twiddles);
        r[0][0] = r[0][0] * first_root;
        r[1][0] = r[1][0] * second_root;
        if (z_count > 1) {
            fr_t first_root_z = get_intermediate_root(idx0, d_partial_twiddles);
            unsigned int off = (nbits - 1) / LG_WINDOW_SIZE;
            unsigned int win = off * LG_WINDOW_SIZE;
            fr_t second_root_z = d_partial_twiddles[off][1 << (nbits - 1 - win)];

            second_root_z *= first_root_z;
            #pragma unroll
            for (int z = 1; z < z_count; z++) {
                first_root *= first_root_z;
                second_root *= second_root_z;
                r[0][z] = r[0][z] * first_root;
                r[1][z] = r[1][z] * second_root;
            }
        }
    }

    if (is_intt && stage == iterations) {
        #pragma unroll
        for (int z = 0; z < z_count; z++) {
            r[0][z] = r[0][z] * d_domain_size_inverse;
            r[1][z] = r[1][z] * d_domain_size_inverse;
        }
    }

    #pragma unroll
    for (int z = 0; z < z_count; z++) {
        d_inout[idx[0][z]] = r[0][z];
        d_inout[idx[1][z]] = r[1][z];
    }
}

template<unsigned int z_count>
__device__ __forceinline__
void gs_coalesced_load(const fr_t* inout, fr_t* shared_mem, fr_t* r,
                       const index_t offset,
                       unsigned int stage, unsigned int iterations)
{
    index_t mask = ((index_t)1 << (stage - iterations)) / z_count - 1;
    index_t idx = (threadIdx.x / z_count) << (stage - iterations);
    idx += (((blockIdx.x & ~mask) << iterations) + (blockIdx.x & mask)) * z_count;
    idx += (threadIdx.x & (z_count - 1)) + offset;

    index_t stride = (blockDim.x / z_count) << (stage - iterations);
    #pragma unroll
    for (int z = 0; z < z_count; z++, idx += stride) {
        r[z] = inout[idx];
    }

    __syncthreads();

    fr_t *xchg = &shared_mem[threadIdx.x];
    #pragma unroll
    for (int z = 0; z < z_count; z++) {
        xchg[blockDim.x * z] = r[z];
    }

    __syncthreads();

    xchg = &shared_mem[threadIdx.x * z_count];
    #pragma unroll
    for (int z = 0; z < z_count; z++) {
        r[z] = xchg[z];
    }
}

template<unsigned int z_count>
__device__ __forceinline__
void gs_coalesced_store(fr_t* inout, fr_t* shared_mem, const fr_t* r,
                        index_t idx, index_t offset,
                        unsigned int stage, unsigned int iterations)
{
    const unsigned int diff_ntt_size = 1 << (iterations - 1);
    const index_t out_ntt_size = (index_t)1 << (stage - 1);

    const index_t stride = (idx & (out_ntt_size - 1)) >> (iterations - 1);
    const index_t current_ntt_idx = (idx & ~(out_ntt_size - 1)) * 2 + stride;
    const index_t thread_ntt_idx = (idx & (diff_ntt_size - 1)) << (stage - iterations + 1);

    offset += thread_ntt_idx + current_ntt_idx;

    const unsigned int x = threadIdx.x & (z_count - 1);
    shared_mem += (threadIdx.x & (0 - z_count)) * z_count;
    fr_t (*xchg)[z_count] = reinterpret_cast<decltype(xchg)>(shared_mem);

    #pragma unroll
    for (int z = 0; z < z_count; z++) {
        xchg[x][z] = r[z];
    }

    __syncwarp();

    #pragma unroll
    for (int z = 0; z < z_count; z++) {
        inout[offset + x + (z << (stage - iterations + 1))] = xchg[z][x];
    }
}

template<unsigned int z_count>
__launch_bounds__(768, 1) __global__
void _GS_NTT_3D(const unsigned int radix, const unsigned int lg_domain_size,
                const unsigned int stage, const unsigned int iterations,
                fr_t* d_inout, const fr_t (*d_partial_twiddles)[WINDOW_SIZE],
                const fr_t* d_radix6_twiddles, const fr_t* d_radixX_twiddles,
                bool is_intt, const fr_t d_domain_size_inverse)
{
#if (__CUDACC_VER_MAJOR__-0) >= 11
    __builtin_assume(lg_domain_size <= MAX_LG_DOMAIN_SIZE);
    __builtin_assume(radix <= 10);
    __builtin_assume(iterations <= radix);
    __builtin_assume(stage <= lg_domain_size && stage >= iterations);
#endif
    extern __shared__ fr_t shared_exchange[];

    index_t tid = threadIdx.x + blockDim.x * (index_t)blockIdx.x;

    const index_t diff_mask = (1 << (iterations - 1)) - 1;
    const index_t inp_ntt_size = (index_t)1 << (stage - 1);
    const index_t out_ntt_size = (index_t)1 << (stage - iterations);

    const index_t tiz = (tid & ~diff_mask) * z_count + (tid & diff_mask);

    fr_t r[2][z_count];

    gs_coalesced_load<z_count>
        (d_inout, shared_exchange, r[0], 0, stage, iterations);
    gs_coalesced_load<z_count>
        (d_inout, shared_exchange, r[1], inp_ntt_size, stage, iterations);

    #pragma unroll 1
    for (int s = iterations; --s >= 6;) {
        unsigned int laneMask = 1 << (s - 1);
        unsigned int thrdMask = (1 << s) - 1;
        unsigned int rank = threadIdx.x & thrdMask;
        bool pos = rank < laneMask;

        fr_t root = d_radixX_twiddles[rank << (radix - (s + 1))];

        #pragma unroll
        for (int z = 0; z < z_count; z++) {
            fr_t t = root * (r[0][z] - r[1][z]);
            r[0][z] = r[0][z] + r[1][z];
            r[1][z] = t;
        }

        __syncthreads();

        fr_t (*xchg)[z_count] = reinterpret_cast<decltype(xchg)>(shared_exchange);
#ifdef __CUDA_ARCH__
        #pragma unroll
        for (int z = 0; z < z_count; z++) {
            fr_t t = fr_t::csel(r[1][z], r[0][z], pos);
            xchg[threadIdx.x][z] = t;
        }

        __syncthreads();

        #pragma unroll
        for (int z = 0; z < z_count; z++) {
            fr_t t = xchg[threadIdx.x ^ laneMask][z];
            r[0][z] = fr_t::csel(t, r[0][z], !pos);
            r[1][z] = fr_t::csel(t, r[1][z], pos);
        }
#endif
    }

    #pragma unroll 1
    for (int s = min(iterations, 6); --s >= 1;) {
        unsigned int laneMask = 1 << (s - 1);
        unsigned int thrdMask = (1 << s) - 1;
        unsigned int rank = threadIdx.x & thrdMask;
        bool pos = rank < laneMask;

        fr_t root = d_radix6_twiddles[rank << (6 - (s + 1))];

        #pragma unroll
        for (int z = 0; z < z_count; z++) {
            fr_t t = root * (r[0][z] - r[1][z]);
            r[0][z] = r[0][z] + r[1][z];
            r[1][z] = t;

#ifdef __CUDA_ARCH__
            t = fr_t::csel(r[1][z], r[0][z], pos);

            shfl_bfly(t, laneMask);

            r[0][z] = fr_t::csel(t, r[0][z], !pos);
            r[1][z] = fr_t::csel(t, r[1][z], pos);
#endif
        }
    }

    #pragma unroll
    for (int z = 0; z < z_count; z++) {
        fr_t t = r[0][z] - r[1][z];
        r[0][z] = r[0][z] + r[1][z];
        r[1][z] = t;
    }

    if (stage - iterations != 0) {
        index_t thread_ntt_pos = (tiz & (inp_ntt_size - 1)) >> (iterations - 1);
        unsigned int thread_ntt_idx = (tiz & diff_mask) * 2;
        unsigned int nbits = MAX_LG_DOMAIN_SIZE - (stage - iterations);
        index_t idx0 = bit_rev(thread_ntt_idx, nbits);
        index_t root_idx0 = idx0 * thread_ntt_pos;
        index_t root_idx1 = root_idx0 + (thread_ntt_pos << (nbits - 1));

        fr_t first_root, second_root;
        get_intermediate_roots(first_root, second_root,
                               root_idx0, root_idx1, d_partial_twiddles);
        r[0][0] = r[0][0] * first_root;
        r[1][0] = r[1][0] * second_root;

        if (z_count > 1) {
            fr_t first_root_z = get_intermediate_root(idx0, d_partial_twiddles);
            unsigned int off = (nbits - 1) / LG_WINDOW_SIZE;
            unsigned int win = off * LG_WINDOW_SIZE;
            fr_t second_root_z = d_partial_twiddles[off][1 << (nbits - 1 - win)];

            second_root_z *= first_root_z;
            #pragma unroll
            for (int z = 1; z < z_count; z++) {
                first_root *= first_root_z;
                second_root *= second_root_z;
                r[0][z] = r[0][z] * first_root;
                r[1][z] = r[1][z] * second_root;
            }
        }
    }

    if (is_intt && stage == iterations) {
        #pragma unroll
        for (int z = 0; z < z_count; z++) {
            r[0][z] = r[0][z] * d_domain_size_inverse;
            r[1][z] = r[1][z] * d_domain_size_inverse;
        }
    }

    gs_coalesced_store<z_count>
        (d_inout, shared_exchange, r[0], tiz & ((index_t)0 - z_count), 0, stage, iterations);
    gs_coalesced_store<z_count>
        (d_inout, shared_exchange, r[1], tiz & ((index_t)0 - z_count), out_ntt_size, stage, iterations);
}

#if defined(FEATURE_BABY_BEAR)
# define Z_COUNT 8
#elif defined(FEATURE_GOLDILOCKS)
# define Z_COUNT 4
#endif

template __global__
void _GS_NTT<1>(unsigned int, unsigned int, unsigned int, unsigned int,
                fr_t*, const fr_t (*)[WINDOW_SIZE], const fr_t*, const fr_t*,
                bool, const fr_t);

template __global__
void _GS_NTT<Z_COUNT>(unsigned int, unsigned int, unsigned int, unsigned int,
                      fr_t*, const fr_t (*)[WINDOW_SIZE], const fr_t*, const fr_t*,
                      bool, const fr_t);
template __global__
void _GS_NTT_3D<Z_COUNT>(unsigned int, unsigned int, unsigned int, unsigned int,
                         fr_t*, const fr_t (*)[WINDOW_SIZE], const fr_t*, const fr_t*,
                         bool, const fr_t);

#ifndef __CUDA_ARCH__

class GS_launcher {
    fr_t* d_inout;
    const int lg_domain_size;
    bool is_intt;
    int stage;
    const NTTParameters& ntt_parameters;
    const cudaStream_t& stream;

public:
    GS_launcher(fr_t* d_ptr, int lg_dsz, bool intt,
                const NTTParameters& params, const cudaStream_t& s)
      : d_inout(d_ptr), lg_domain_size(lg_dsz), is_intt(intt), stage(lg_dsz),
        ntt_parameters(params), stream(s)
    {}

    void step(int iterations)
    {
        assert(iterations <= 10);

        const int radix = iterations < 6 ? 6 : iterations;

        index_t num_threads = (index_t)1 << (lg_domain_size - 1);
        index_t block_size = 1 << (radix - 1);
        index_t num_blocks;

        block_size = (num_threads <= block_size) ? num_threads : block_size;
        num_blocks = (num_threads + block_size - 1) / block_size;

        assert(num_blocks == (unsigned int)num_blocks);

        fr_t* d_radixX_twiddles = nullptr;

        switch (radix) {
        case 7:
            d_radixX_twiddles = ntt_parameters.radix7_twiddles;
            break;
        case 8:
            d_radixX_twiddles = ntt_parameters.radix8_twiddles;
            break;
        case 9:
            d_radixX_twiddles = ntt_parameters.radix9_twiddles;
            break;
        case 10:
            d_radixX_twiddles = ntt_parameters.radix10_twiddles;
            break;
        }

        size_t shared_sz = sizeof(fr_t) << (radix - 1);
        #define NTT_ARGUMENTS radix, lg_domain_size, stage, iterations, \
                d_inout, ntt_parameters.partial_twiddles, \
                ntt_parameters.radix6_twiddles, d_radixX_twiddles, \
                is_intt, domain_size_inverse[lg_domain_size]

        if (num_blocks < Z_COUNT)
            _GS_NTT<1><<<num_blocks, block_size, shared_sz, stream>>>(NTT_ARGUMENTS);
        else if (stage == iterations || lg_domain_size < 12)
            _GS_NTT<Z_COUNT><<<num_blocks/Z_COUNT, block_size, Z_COUNT*shared_sz, stream>>>(NTT_ARGUMENTS);
        else
            _GS_NTT_3D<Z_COUNT><<<num_blocks/Z_COUNT, block_size, Z_COUNT*shared_sz, stream>>>(NTT_ARGUMENTS);

        #undef NTT_ARGUMENTS

        stage -= iterations;
    }
};

#undef Z_COUNT

void GS_NTT(fr_t* d_inout, const int lg_domain_size, bool intt,
            const NTTParameters& ntt_parameters, const cudaStream_t& stream)
{
    GS_launcher params{d_inout, lg_domain_size, intt, ntt_parameters, stream};

    if (lg_domain_size <= std::min(10, MAX_LG_DOMAIN_SIZE)) {
        params.step(lg_domain_size);
    } else if (lg_domain_size <= std::min(12, MAX_LG_DOMAIN_SIZE)) {
        params.step(lg_domain_size - 6);
        params.step(6);
    } else if (lg_domain_size <= std::min(18, MAX_LG_DOMAIN_SIZE)) {
        params.step(lg_domain_size / 2 + lg_domain_size % 2);
        params.step(lg_domain_size / 2);
    } else if (lg_domain_size <= std::min(30, MAX_LG_DOMAIN_SIZE)) {
        int step = lg_domain_size / 3;
        int rem = lg_domain_size % 3;
        params.step(step + (lg_domain_size == 29 ? 1 : rem));
        params.step(step + (lg_domain_size == 29 ? 1 : 0));
        params.step(step);
    } else if (lg_domain_size <= std::min(32, MAX_LG_DOMAIN_SIZE)) {
        int step = lg_domain_size / 4;
        int rem = lg_domain_size % 4;
        params.step(step + rem);
        params.step(step);
        params.step(step);
        params.step(step);
    } else {
        assert(false);
    }
}

#endif
