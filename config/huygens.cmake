set (ENV{NETCDF_ROOT} $ENV{SARA_NETCDF_ROOT})
set (ENV{HDF5_ROOT} $ENV{SARA_HDF5_ROOT} /sara/sw/zlib/1.2.5/)
set (ENV{FFTW_ROOT} $ENV{SARA_FFTW3_ROOT})
set (CMAKE_LIBRARY_PATH /usr/lib64)
find_library(LAPACK_LIBRARIES essl)
ADD_DEFINITIONS("-DESSL=TRUE")  # Set precompiler flag
