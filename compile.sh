nvcc -c -g -G cublas_fortran.cu
ftn -c -g cublas_fortran_iso.f90
ftn -g -D_MPI_ -c -I/ccs/home/ssawyer1/exciting-plus-rgvw-mod/src/ genmegqblh_cublas.f90


cp genmegqblh_cublas.o src/addons/expigqr/genmegqblh.o
cp cublas_fortran_iso.o  cublas_fortran.o *.mod src/addons/expigqr/

make


