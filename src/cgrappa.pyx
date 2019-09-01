# distutils: language = c++
# cython: language_level=3

from time import time

import numpy as np
cimport numpy as np
from skimage.util import pad, view_as_windows
from libcpp.map cimport map
from libcpp.vector cimport vector
cimport cython
from cython.operator cimport dereference, postincrement

# Define a vector of uints for use in map definition
ctypedef vector[unsigned int] vector_uint

# This allows us to use the C function in this cython module
cdef extern from "get_sampling_patterns.h":
    map[unsigned long long int, vector_uint] get_sampling_patterns(
        int*, unsigned int, unsigned int,
        unsigned int, unsigned int)

@cython.boundscheck(False)
@cython.wraparound(False)
def cgrappa(
        kspace, calib, kernel_size=(5, 5), lamda=.01,
        int coil_axis=-1, silent=True, ret_weights=False):

    # Put coil axis in the back
    kspace = np.moveaxis(kspace, coil_axis, -1)
    calib = np.moveaxis(calib, coil_axis, -1)

    # Make sure we're contiguous
    kspace = np.ascontiguousarray(kspace)
    mask = np.ascontiguousarray(
        (np.abs(kspace[:, :, 0]) > 0).astype(np.int32))

    # Let's define all the C types we'll be using
    cdef:
        Py_ssize_t kx, ky, nc
        Py_ssize_t cx, cy,
        Py_ssize_t ksx, ksy, ksx2, ksy2,
        Py_ssize_t adjx, adjy
        Py_ssize_t xx, yy
        Py_ssize_t ii
        Py_ssize_t[:] x
        Py_ssize_t[:] y
        # complex[:, :, ::1] kspace_memview = kspace
        int[:, ::1] mask_memview = mask
        map[unsigned long long int, vector_uint] res
        map[unsigned long long int, vector_uint].iterator it

    # Get size of arrays
    kx, ky, nc = kspace.shape[:]
    cx, cy, nc = calib.shape[:]
    ksx, ksy = kernel_size[:]
    ksx2, ksy2 = int(ksx/2), int(ksy/2)
    adjx = np.mod(ksx, 2)
    adjy = np.mod(ksy, 2)

    # Pad the arrays
    kspace = pad(
        kspace, ((ksx2, ksx2), (ksy2, ksy2), (0, 0)), mode='constant')
    calib = pad(
        calib, ((ksx2, ksx2), (ksy2, ksy2), (0, 0)), mode='constant')

    # Pass in arguments to C function, arrays pass pointer to start
    # of arrays, i.e., [x=0, y=0, coil=0].
    t0 = time()
    res = get_sampling_patterns(
        &mask_memview[0, 0],
        kx, ky,
        ksx, ksy)
    if not silent:
        print('Find unique sampling patterns: %g' % (time() - t0))

    # Get all overlapping patches of ACS
    t0 = time()
    A = view_as_windows(
        calib, (ksx, ksy, nc)).reshape((-1, ksx, ksy, nc))
    cdef complex[:, :, :, ::1] A_memview = A
    if not silent:
        print('Make calibration patches: %g' % (time() - t0))

    # Train and apply weights
    if ret_weights: # if the user wants weights, add 'em to the list
        Ws = []
    t0 = time()
    it = res.begin()
    while(it != res.end()):

        # The key is a decimal number representing a binary number
        # whose bits describe the sampling mask.  First convert to
        # binary with ksx*ksy bits, reverse (since lowest bit
        # is the upper left of the sampling pattern), convert to
        # boolean array, and then repmat to get the right number of
        # coils.
        P = format(dereference(it).first, 'b').zfill(ksx*ksy)
        P = (np.fromstring(P[::-1], np.int8) - ord('0')).reshape(
            (ksx, ksy)).astype(bool)
        P = np.tile(P[..., None], (1, 1, nc))

        # Train the weights for this pattern
        S = A[:, P]
        T = A_memview[:, ksx2, ksy2, :]
        ShS = S.conj().T @ S
        ShT = S.conj().T @ T
        lamda0 = lamda*np.linalg.norm(ShS)/ShS.shape[0]
        W = np.linalg.solve(
            ShS + lamda0*np.eye(ShS.shape[0]), ShT).T

        if ret_weights:
            Ws.append(W)

        # For each hole that uses this pattern, fill in the recon
        idx = dereference(it).second
        x, y = np.unravel_index(idx, (kx, ky))
        for ii in range(x.size):
            xx, yy = x[ii], y[ii]
            xx += ksx2
            yy += ksy2

            # Collect sources for this hole and apply weights
            S = kspace[xx-ksx2:xx+ksx2+adjx, yy-ksy2:yy+ksy2+adjy, :]
            S = S[P]
            kspace[xx, yy, :] = (W @ S[:, None]).squeeze()

        # Move to the next sampling pattern
        postincrement(it)

    if not silent:
        print('Training and application of weights: %g' % (
            time() - t0))

    # Give the user the weights if desired
    if ret_weights:
        return(np.moveaxis(
            kspace[ksx2:-ksx2, ksy2:-ksy2, :], -1, coil_axis), Ws)
    return np.moveaxis(
        kspace[ksx2:-ksx2, ksy2:-ksy2, :], -1, coil_axis)
