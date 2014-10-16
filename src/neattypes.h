#pragma once

// Some common types that must be in their own header so they can be used by the
// CUDA compiler (C++11 features not currently supported).
namespace NEAT {

    typedef float real_t;

    typedef unsigned char uchar;
    typedef unsigned short ushort;

	enum nodetype {
        NT_BIAS = 0,
		NT_SENSOR = 1,
		NT_OUTPUT = 2,
		NT_HIDDEN = 3
	};

    #define __in const
    #define __out
    #define __inout
}