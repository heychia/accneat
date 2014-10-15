#define DEVICE_CODE

#include <iostream>
#include <vector>

#include "cudanetwork.h"

#include <assert.h>
#include <cuda.h>
#include <limits.h>
#include <stdio.h>

//--------------------------------------------------------------------------------
//---
//--- MACROS
//---
//--------------------------------------------------------------------------------
#define errif( STMT, MSG... ) if( STMT ) { fprintf(stderr, "[%s:%d] '%s' ", __FILE__, __LINE__, #STMT); fprintf(stderr, MSG); fprintf(stderr, "\n"); abort(); }
#define require( STMT ) if( !(STMT) ) { fprintf(stderr, "ASSERTION ERROR! [%s:%d] '%s'\n", __FILE__, __LINE__, #STMT); abort(); }
#define panic() { fprintf(stderr, "PANIC! [%s:%d]\n", __FILE__, __LINE__); abort(); }
#define trap(msg) {std::cerr << __FILE__ << ":" << __LINE__ << ": " << msg << std::endl; abort();}

#define p(msg) std::cout << "[cuda]: " << msg << std::endl

#define Threads_Per_Block 1
#define MAX_NEURONS Threads_Per_Block
#define NACTIVATE_ITERATIONS 10

#define xcuda(stmt) {                                                   \
        cudaError_t err = stmt;                                         \
        if (err != cudaSuccess) {                                       \
            std::cerr << __FILE__ << ":" << __LINE__ << ": Failed to run " << #stmt << ". Reason: " << cudaGetErrorString(err) << std::endl; \
            exit(1);                                                    \
        }                                                               \
    }

namespace NEAT {
    __global__ void activate(GpuState *states,
                             RawBuffers bufs,
                             uint ncycles);

    static uchar *alloc_host(uint size) {
        uchar *result;
        xcuda( cudaMallocHost((void **)&result, size) );
        return result;
    }
    static uchar *alloc_dev(uint size) {
        uchar *result;
        xcuda( cudaMalloc((void **)&result, size) );
        return result;
    }
    static void free_host(__inout uchar *&buf) {
        if(buf) {
            xcuda( cudaFreeHost(buf) );
            buf = 0;
        }
    }
    static void free_dev(__inout uchar *&buf) {
        if(buf) {
            xcuda( cudaFree(buf) );
            buf = 0;
        }
    }
    static void grow_buffers(__inout uchar *&h_buf, __inout uchar *&d_buf,
                             __inout uint &capacity, __in uint newlen) {
        free_host(h_buf);
        free_dev(d_buf);
        capacity = newlen;
        h_buf = alloc_host(newlen);
        d_buf = alloc_dev(newlen);
    }

#define __dh_util static inline __device__ __host__

    __dh_util CudaLink *links(const RawBuffers &bufs,
                              const Offsets &offs) {
        return (CudaLink *)(bufs.main + offs.main.links);
    }

    __dh_util ActivationPartition *partitions(const RawBuffers &bufs,
                                              const Offsets &offs) {
        return (ActivationPartition *)(bufs.main + offs.main.partitions);
    }

    __dh_util real_t *input_activations(const RawBuffers &bufs,
                                        const Offsets &offs) {
        return (real_t *)(bufs.input + offs.input.activation);
    }

    __dh_util real_t *hidden_activations(const RawBuffers &bufs,
                                         const Offsets &offs) {
        return (real_t *)(bufs.main + offs.main.activation);
    }

    __dh_util real_t *output_activations(const RawBuffers &bufs,
                                         const Offsets &offs) {
        return (real_t *)(bufs.output + offs.output.activation);
    }

    __dh_util ActivateParms &activate_parms(const RawBuffers &bufs,
                                            const Offsets &offs) {
        return *(ActivateParms *)(bufs.input + offs.input.activate_parms);
    }

#undef __dh_util

//--------------------------------------------------------------------------------
//---
//--- CLASS CudaNetworkBatch
//---
//--------------------------------------------------------------------------------
    CudaNetworkBatch::CudaNetworkBatch(uint nnets_)
        : nnets(nnets_) {
        memset(&h_bufs, 0, sizeof(h_bufs));
        memset(&d_bufs, 0, sizeof(d_bufs));
        memset(&offsets, 0, sizeof(offsets));
        memset(&capacity, 0, sizeof(capacity));
        memset(&lens, 0, sizeof(lens));

        h_gpu_states = (GpuState *)alloc_host(sizeof(GpuState) * nnets);
        d_gpu_states = (GpuState *)alloc_dev(sizeof(GpuState) * nnets);
    }

    CudaNetworkBatch::~CudaNetworkBatch() {
        free_host((uchar *&)h_gpu_states);
        free_dev((uchar *&)d_gpu_states);

        free_host(h_bufs.main);
        free_host(h_bufs.input);
        free_host(h_bufs.output);

        free_dev(d_bufs.main);
        free_dev(d_bufs.input);
        free_dev(d_bufs.output);
    }

    void CudaNetworkBatch::configure(CudaNetwork **nets,
                                     uint nnets) {
        assert(nnets = this->nnets);

        memset(&lens, 0, sizeof(lens));
        sizeof_shared = 0;

        Offsets nets_offs[nnets];

        for(uint i = 0; i < nnets; i++) {
            CudaNetwork &net = *nets[i];
            CudaNetDims &dims = net.dims;

            Lens net_lens;
            Offsets &net_offs = nets_offs[i];
            uint net_sizeof_shared =
                (2 * sizeof(real_t) * dims.nnodes.all)
                + (sizeof(real_t) * Threads_Per_Block);

            //main buffer
            {
                uint sizeof_activation = sizeof(real_t) * dims.nnodes.hidden;
                uint sizeof_links = sizeof(CudaLink) * dims.nlinks;
                uint sizeof_partitions = sizeof(ActivationPartition) * dims.npartitions;

                net_lens.main = sizeof_activation + sizeof_links + sizeof_partitions;

                net_offs.main.activation = this->lens.main;
                // gpu requires proper alignment
                assert(net_offs.main.activation % sizeof(real_t) == 0);
                net_offs.main.links = net_offs.main.activation + sizeof_activation;
                net_offs.main.partitions = net_offs.main.links + sizeof_links;
            }

            //input buffer
            {
                uint sizeof_parms = sizeof(ActivateParms);
                uint sizeof_activation = sizeof(real_t) * dims.nnodes.sensor;

                net_lens.input = sizeof_parms + sizeof_activation;

                net_offs.input.activate_parms = this->lens.input;
                net_offs.input.activation = net_offs.input.activate_parms + sizeof_parms;
                // gpu requires proper alignment
                assert(net_offs.input.activation % sizeof(real_t) == 0);
            }

            //output buffer
            {
                uint sizeof_activation = sizeof(real_t) * dims.nnodes.output;

                net_lens.output = sizeof_activation;

                net_offs.output.activation = this->lens.output;
                // gpu requires proper alignment
                assert(net_offs.output.activation % sizeof(real_t) == 0);
            }

            sizeof_shared = max(sizeof_shared, net_sizeof_shared);
            
            net.offsets = net_offs;
            lens += net_lens;
        }

        if(lens.main > capacity.main) {
            uint newlen = uint(lens.main * 1.4);
            p("alloc main: " << newlen);
            grow_buffers(h_bufs.main, d_bufs.main, capacity.main, newlen);
        }
        if(lens.input > capacity.input) {
            uint newlen = uint(lens.input);
            p("alloc input: " << newlen);
            assert(capacity.input == 0); // should only alloc once
            grow_buffers(h_bufs.input, d_bufs.input, capacity.input, newlen);
        }
        if(lens.output > capacity.output) {
            uint newlen = uint(lens.output);
            p("alloc output: " << newlen);
            assert(capacity.output == 0); // should only alloc once
            grow_buffers(h_bufs.output, d_bufs.output, capacity.output, newlen);
        }

        for(uint i = 0; i < nnets; i++) {
            CudaNetwork *net = nets[i];
            net->set_bufs(h_bufs, nets_offs[i]);

            GpuState &gpu = h_gpu_states[i];
            gpu.dims = net->dims;
            gpu.offsets = net->offsets;
        }

        xcuda( cudaMemcpy(d_gpu_states, h_gpu_states, sizeof(GpuState) * nnets, cudaMemcpyHostToDevice) );
        xcuda( cudaMemcpy(d_bufs.main, h_bufs.main, lens.main, cudaMemcpyHostToDevice) );
    }

    void CudaNetworkBatch::activate(uint ncycles) {
        std::cout << "input[0]=" << (int)h_bufs.input[0] << std::endl;

        xcuda( cudaMemcpy(d_bufs.input,
                          h_bufs.input,
                          lens.input,
                          cudaMemcpyHostToDevice) );

        NEAT::activate<<<nnets, Threads_Per_Block, sizeof_shared>>>(d_gpu_states,
                                                                    d_bufs,
                                                                    ncycles);
        
        xcuda( cudaMemcpy(h_bufs.output,
                          d_bufs.output,
                          lens.output,
                          cudaMemcpyDeviceToHost) );
    }

    void CudaNetworkBatch::get_activations(CudaNetwork *net,
                                           __out std::vector<real_t> &result) {
        result.clear();
        for(size_t i = 0; i < net->dims.nnodes.bias; i++) {
            result.push_back(1.0);
        }

        for(size_t i = 0; i < net->dims.nnodes.sensor; i++) {
            result.push_back(input_activations(h_bufs, net->offsets)[i]);
        }

        for(size_t i = 0; i < net->dims.nnodes.output; i++) {
            result.push_back(output_activations(h_bufs, net->offsets)[i]);
        }

        real_t hidden[net->dims.nnodes.hidden];
        xcuda( cudaMemcpy(hidden, hidden_activations(d_bufs, net->offsets), sizeof(hidden), cudaMemcpyDeviceToHost) );

        for(size_t i = 0; i < net->dims.nnodes.hidden; i++) {
            result.push_back(hidden[i]);
        }
    }

//--------------------------------------------------------------------------------
//---
//--- CLASS CudaNetwork
//---
//--------------------------------------------------------------------------------
    void CudaNetwork::set_bufs(const RawBuffers &bufs_,
                               const Offsets &offsets_) {
        bufs = bufs_;
        offsets = offsets_;

        memcpy( NEAT::links(bufs, offsets),
                gpu_links.data(),
                sizeof(CudaLink) * gpu_links.size() );
        memcpy( NEAT::partitions(bufs, offsets),
                partitions.data(),
                sizeof(ActivationPartition) * partitions.size() );

        activate_parms(bufs, offsets).clear_noninput = true;
        activate_parms(bufs, offsets).enabled = true;
    }

    void CudaNetwork::set_clear_noninput(bool val) {
        activate_parms(bufs, offsets).clear_noninput = val;
    }

    void CudaNetwork::disable() {
        activate_parms(bufs, offsets).enabled = false;
    }

    bool CudaNetwork::is_enabled() {
        return activate_parms(bufs, offsets).enabled;
    }

    void CudaNetwork::configure(const NetDims &dims_,
                                NetNode *nodes,
                                NetLink *links) {

        static_cast<NetDims &>(dims) = dims_;

        partitions.clear();
        gpu_links.resize(dims.nlinks);

        if(dims.nlinks != 0) {
            ActivationPartition partition;

            for(link_size_t i = 0; i < dims.nlinks; i++) {
                NetLink &link = links[i];
                if( (i % Threads_Per_Block == 0)
                    || (link.out_node_index != partition.out_node_index) ) {

                    if(i != 0) {
                        partitions.push_back(partition);
                    }

                    partition.out_node_index = link.out_node_index;
                    partition.offset = i % Threads_Per_Block;
                    partition.len = 0;
                }
                partition.len++;

                CudaLink &gpu_link = gpu_links[i];
                gpu_link.in_node_index = link.in_node_index;
                gpu_link.partition = partitions.size();
                gpu_link.weight = link.weight;
            }

            partitions.push_back(partition);
        }
        dims.npartitions = partitions.size();
    }

    void CudaNetwork::load_sensors(const std::vector<real_t> &sensvals,
                                   bool clear_noninput) {
        memcpy( input_activations(bufs, offsets),
                sensvals.data(),
                sizeof(real_t) * dims.nnodes.sensor );

        if(clear_noninput) {
            activate_parms(bufs, offsets).clear_noninput = clear_noninput;
        }
    }

    real_t CudaNetwork::get_output(size_t index) {
        return output_activations(bufs, offsets)[index];
    }

//--------------------------------------------------------------------------------
//---
//--- GPU KERNEL CODE
//---
//--------------------------------------------------------------------------------
    __device__ void sum_partition(float *x, int i, int n, float *result) {
        int stride = __popc(n) == 1 ? n >> 1 : 1 << 31 - __clz(n);

        if( (stride > 0) && (i + stride < n) ) {
            x[i] += x[i + stride];
        }
      
        __syncthreads();

        stride >>= 1;
        // max_stride necessary to keep all threads from all partitions in sync.
        for(int max_stride = Threads_Per_Block >> 1; max_stride > 0; stride >>= 1, max_stride >>= 1) {
            if(i < stride) {
                x[i] += x[i + stride];
            }
            __syncthreads();
        }

        if(i == 0) {
            *result += x[0];
        }

        __syncthreads();
    }

    __global__ void test_sum_partition_kernel(float *x, int n, float *result) {
        uint tid = threadIdx.x;
        __shared__ float shx[Threads_Per_Block];
        *result = 0;
        int i;
        if(tid < n) {
            shx[tid] = x[tid];
            i = tid;
        } else {
            i = 1; n = 0;
        }
        sum_partition(shx, i, n, result);
    }

    inline __device__ real_t fsigmoid(real_t activesum,real_t slope,real_t constant) {
        //NON-SHIFTED STEEPENED
        return (1/(1+(exp(-(slope*activesum))))); //Compressed
    }

    __global__ void activate(GpuState *states,
                             RawBuffers bufs,
                             uint ncycles) {
        GpuState state = states[blockIdx.x];
        if(!activate_parms(bufs, state.offsets).enabled) {
            return;
        }
        // to print input:
        // p *(@global float * @local)(bufs.input + state.offsets.input.activation)@N

        extern __shared__ char __shared_buf[];

        // in cuda-gdb: print *((@shared float*)activation + i)
        //              print *((@shared float*)newactivation)@6
        real_t *activation = (real_t *)__shared_buf;
        real_t *newactivation = activation + state.dims.nnodes.all;
        real_t *partial_activation = newactivation + state.dims.nnodes.all;

        uint tid = threadIdx.x;

        for(uint inode = tid; inode < state.dims.nnodes.all; inode += Threads_Per_Block) {
            if(inode < state.dims.nnodes.input) {
                const uint nbias = state.dims.nnodes.bias;
                if(inode < nbias) {
                    activation[inode] = 1.0;
                } else {
                    activation[inode] =
                        input_activations(bufs, state.offsets)[inode - nbias];
                }
                newactivation[inode] = activation[inode];
            } else {
                const uint nio = state.dims.nnodes.input + state.dims.nnodes.output;
                if( activate_parms(bufs, state.offsets).clear_noninput ) {
                    activation[inode] = 0.0;
                } else {
                    activation[inode] =
                        hidden_activations(bufs, state.offsets)[inode - nio];
                }
            }
        }
        __syncthreads();

        const int nits = 1 + (state.dims.nlinks - 1) / Threads_Per_Block;

        for(uint icycle = 0; icycle < ncycles; icycle++) {
            for(uint inode = tid + state.dims.nnodes.input;
                inode < state.dims.nnodes.all;
                inode += Threads_Per_Block) {
                newactivation[inode] = 0.0;
            }
            __syncthreads();

            for(uint ilink = tid, it = 0; it < nits; ilink += Threads_Per_Block, it++) {
                float *partition_x;
                int partition_i;
                int partition_n;
                float *result;

                if(ilink < state.dims.nlinks) {
                    CudaLink link = links(bufs, state.offsets)[ilink];
                    partial_activation[tid] = link.weight * activation[link.in_node_index];

                    ActivationPartition p = partitions(bufs, state.offsets)[link.partition];
                    partition_x = partial_activation + p.offset;
                    partition_i = tid - p.offset;
                    partition_n = p.len;
                    result = newactivation + p.out_node_index;
                } else {
                    partition_x = NULL;
                    partition_i = 1;
                    partition_n = 0;
                    result = NULL;
                }
                __syncthreads();

                sum_partition(partition_x,
                              partition_i,
                              partition_n,
                              result);

                __syncthreads();
            }

            for(uint inode = tid + state.dims.nnodes.input; inode < state.dims.nnodes.all; inode += Threads_Per_Block) {
                newactivation[inode] = fsigmoid(newactivation[inode],
                                                4.924273,
                                                2.4621365);
            }
            {
                float *swap = newactivation;
                newactivation = activation;
                activation = swap;
            }
            __syncthreads();
        }

        const uint nio = state.dims.nnodes.input + state.dims.nnodes.output;

        for(uint inode = tid + state.dims.nnodes.input;
            inode < state.dims.nnodes.all;
            inode += Threads_Per_Block) {

            if(inode < nio) {
                output_activations(bufs, state.offsets)[inode - state.dims.nnodes.input] = activation[inode];
            } else {
                hidden_activations(bufs, state.offsets)[inode - nio] = activation[inode];
            }
        }
    }

    void test_sum_partition() {
        for(size_t n = 1; n <= Threads_Per_Block; n++) {
            real_t x[n];
            size_t sizeof_x = sizeof(real_t) * n;

            real_t expected = 0.0;
            for(size_t i = 0; i < n; i++) {
                //x[i] = real_t(i) + 1;
                x[i] = drand48();
                expected += x[i];
            }

            real_t actual = -100;

            real_t *d_x = (real_t *)alloc_dev(sizeof_x);
            xcuda( cudaMemcpy(d_x,
                              x,
                              sizeof_x,
                              cudaMemcpyHostToDevice) );

            real_t *d_actual = (real_t *)alloc_dev(sizeof(real_t));

            NEAT::test_sum_partition_kernel<<<1, Threads_Per_Block>>>(d_x, n, d_actual);
            
            xcuda( cudaMemcpy(&actual,
                              d_actual,
                              sizeof(real_t),
                              cudaMemcpyDeviceToHost) );

            if( fabs(expected - actual) / expected >= 0.05 ) {
                std::cout << "n=" << n << ", Expected=" << expected << ", Actual=" << actual << std::endl;
            }
        }
            
        exit(0);
    }

} // namespace NEAT
