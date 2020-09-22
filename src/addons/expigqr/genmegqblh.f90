subroutine genmegqblh(iq,ikloc,ngknr1,ngknr2,igkignr1,igkignr2,wfsvmt1,wfsvmt2,&
                      wfsvit1,wfsvit2)
  USE modmain, ONLY: zzero, zone, natmtot, nstsv, nkptnr, &
                     ngrid, ngrtot, ngkmax, ivg, &
                     lmmaxapw, nufrmax, nspinor, spinpol, igfft, ivgig, cfunir
  USE mod_mpi_grid
  USE mod_timer
  USE mod_papi
  USE mod_prec
  USE mod_addons, ONLY: debug_level, dim_k, &
                        pt_megqblh, pt_megqblh_mt, pt_megqblh_it
  USE mod_addons_q, ONLY: ngq, igqig, sfacgq
  USE mod_nrkp, ONLY: spinor_ud
  USE mod_expigqr, ONLY: expigqr22, gntuju, megqblh, bmegqblh, nmegqblh, &
                         idxkq, nbandblhloc, ltranblhloc, ntranblhloc, &
                         idxtranblhloc
  USE mod_genmegqblh_gpu
#ifdef  _USE_3M_
  USE mod_lapack, ONLY: ZGEMM3M, ZCOPY
#else
  USE mod_lapack, ONLY: ZGEMM, ZCOPY
#endif /* _USE_3M_ */

  implicit none
  integer, intent(in) :: iq
  integer, intent(in) :: ikloc
  integer, intent(in) :: ngknr1
  integer, intent(in) :: ngknr2
  integer, intent(in) :: igkignr1(ngkmax)
  integer, intent(in) :: igkignr2(ngkmax)
  complex(8), intent(in) :: wfsvmt1(lmmaxapw*nufrmax,natmtot,nspinor,nstsv)
  complex(8), intent(in) :: wfsvmt2(lmmaxapw,nufrmax,natmtot,nspinor,nstsv)
  complex(8), intent(in) :: wfsvit1(ngkmax,nspinor,nstsv)
  complex(8), intent(in) :: wfsvit2(ngkmax,nspinor,nstsv)

  integer wfsize
  integer ivg1(3)
  integer i,j,ik,jk,igkq,n1,ispn1,ispn2,ist1,ist2,ic,j1
  integer ig,ig1,ig2,ias,ifg,ir,imt
  logical l1

  ! Temporary array for interstitial calculation (FFT)
  COMPLEX(KIND=dz), DIMENSION(:), ALLOCATABLE :: wfir1
 
#if defined(_DEBUG_bmegqblh_) || defined(_DEBUG_megqblh_) || EBUG > 0
  INTEGER :: dbgcnt0, dbgcnt1, dbgcnt2
  INTEGER :: dbgunit1, dbgunit2
#endif /* _DEBUG_bmegqblh_ || _DEBUG_megqblh_ || DEBUG */

  ! Number of bands associated with the ket state vectors that are involved in
  ! the matrix elements (band transitions)
  INTEGER :: ntran

  ! Loop/dummy indices
  INTEGER :: iband, idxtran, ispst, ibatch, iblock

!--DEBUG

  ! Note: List of OpenACC variables that are already in device memory 
  !       due to inheritance from mod_expigqr::genmegq() :
  !         sfacgq, gntuju, bmegqblh, idxhibandblhloc, idxtranblhloc,
  !         spinor_ud, ngq, ias2ic

  ! Set constants on both CPU and device
  CALL genmegqblh_allocmodvar_const( ikloc, iq )

  ! TODO: move this into the module
  wfsize = nmt*natmtot + ngknr2

  ! TODO: move this into the module
!  !$ACC DATA COPYIN( wfsize, ngknr2 )
  allocate(wftmp1(wfsize,ngqiq)) ! TODO: Change dimensions appropriately
  allocate(wftmp2(wfsize,nstsv)) ! TODO: Check contiguity of ZCOPY transfers
  allocate(wfir1(ngrtot))

  CALL papi_timer_start(pt_megqblh)

  ! global k-point
  ik = mpi_grid_map(nkptnr,dim_k,loc=ikloc)

  ! jk = k + q - G_q
  jk = idxkq(1,ik)

  ! G_q vector 
  igkq = idxkq(2,ik)

#ifdef _DEBUG_bmegqblh_
  dbgunit1 = 1000 + iproc ! Make sure this matches the definition in mod_expigqr::genmegq()
  WRITE( dbgunit1, '(A,I3,A,I5)' ) 'nmegqblh(ikloc=', ikloc, ') = ', nmegqblh(ikloc)
#endif /* _DEBUG_bmegqblh_ */

#ifdef _DEBUG_megqblh_
  dbgunit2 = 2000 + iproc ! Make sure this matches the definition in mod_expigqr::genmegq()
#endif

!--DEBUG
#if EBUG >= 1
  WRITE(*,*) 'genmegqblh: iq=', iq, ' ikloc=', ikloc, ' ngq(iq)=', ngq(iq)
#endif
!--DEBUG

#if defined(_DEBUG_megqblh_) && EBUG >= 3
  dbgcnt0 = 0
#endif /* _DEBUG_megqblh_ */

  ! Begin loop over spin projections (nspinor = 1 when spinpol is .FALSE.)
  do ispn1=1,nspinor

#if defined(_DEBUG_megqblh_) && EBUG >= 3
     dbgcnt1 = 0
#endif /* _DEBUG_megqblh_ */

     ! expigqr22 is always 1, for now (see mod_expigqr)
     if (expigqr22.eq.1) ispn2=ispn1

!--begin Convert to true ZGEMM

     call timer_start(3)
     call papi_timer_start(pt_megqblh_mt)

     ! Allocate array for table of states for each spin projection
     CALL genmegqblh_allocmodvar_spin

!------------------------------------------------------------------------------
! Kernel 0: Count spin states per spin projection
!------------------------------------------------------------------------------

     ! Count spin states for this particular k-vector (replaces l1 check)
     ! Note: spinup and spindn are defined in mod_genmegqblh_gpu
     IF( ispn1 == 1 ) THEN
        ! Spin up
        CALL genmegqblh_countspin( spinup, ikloc )
     ELSE
        ! Spin down (never executed if spinpol = .FALSE. )
        CALL genmegqblh_countspin( spindn, ikloc )
     END IF

     ! Fetch kernel result and transfer D->H
     ! TODO: move this into the module
     !$ACC UPDATE HOST( spinstidx, nstspin )
     !$ACC WAIT

     ! Allocate/copy arrays related to muffin-tin calculation (batched ZGEMM)
     CALL genmegqblh_allocmodvar_mt

!------------------------------------------------------------------------------
! Kernel 1: Fill in bgntuju (or dptr_gntuju) and b1 arrays, and zero b2 array
!------------------------------------------------------------------------------

!--DEBUG
#if EBUG >= 2
     WRITE(*,*) 'genmegqblh: before 1st kernel'
#endif
!--DEBUG

     CALL genmegqblh_fillbatch( wfsvmt1, ikloc, ispn1 )

!--DEBUG
#if EBUG >= 2
     WRITE(*,*) 'genmegqblh: after 1st kernel'
#endif
!--DEBUG
     
!------------------------------------------------------------------------------
! Kernel 2: Perform batched ZGEMM b2(:,:) = bgntuju(:,:) x b1(:,:)
!------------------------------------------------------------------------------

#if EBUG >= 2
     WRITE(*,*) 'genmegqblh: before 2nd kernel'
#endif /* DEBUG */

     ! Original code (retained for historical purpose)
     !do j=1,ngntuju(ic,ig)
     !  b2(igntuju(2,j,ic,ig))=b2(igntuju(2,j,ic,ig))+&
     !    &b1(igntuju(1,j,ic,ig))*gntuju(j,ic,ig)
     !enddo

     ! Improved code (retained for pedagogical purpose)
     !CALL zgemm( 'N', 'N', nband1, nmt, nmt &
     !            zone,  bgntuju, nmt, &
     !                   b1,      nmt, &
     !            zzero, b2 )

     CALL genmegqblh_batchzgemm()

#if EBUG >=2
     WRITE(*,*) 'genmegqblh: after 2nd kernel'
#endif /* DEBUG */

#if EBUG >= 3
     !$ACC UPDATE HOST( nbatch1 )
     WRITE(*,*) 'genmegqblh: nbatch1=', nbatch1 
#endif /* DEBUG */

!------------------------------------------------------------------------------
! Kernel 3: Save results to wftmp1mt and transfer back to CPU (for now)
!------------------------------------------------------------------------------

!--DEBUG
#if EBUG >= 2
     WRITE(*,*) 'genmegqblh: before 3rd kernel'
#endif
!--DEBUG

     CALL genmegqblh_fillresult( wftmp1mt )

!--DEBUG
#if EBUG >= 2     
     WRITE(*,*) 'genmegqblh: after 3rd kernel'
#endif
!--DEBUG

!------------------------------------------------------------------------------

     call timer_stop(3)
     call papi_timer_stop(pt_megqblh_mt)

     ! Transfer data D->H (for now)
     ! TODO: move this into the module
     !$ACC UPDATE SELF( wftmp1mt )

     ! Start the bounded do loop for each band
     DO ispst = 1, nstspin

        ! left <bra| state
        wftmp1(:,:) = zzero

        ! Note: wftmp1 combines the muffin-tin and interstitial parts
        !       for each band, to prepare for the second ZGEMM below
        !       Complete removal of wftmp1mt is impossible until
        !       interstitial part also ported to GPU
        !       (cuFFT with fallback to FFTW)
        DO ig = 1, ngqiq
           DO ias = 1, natmtot
              CALL ZCOPY( nmt, &
                          wftmp1mt(1,ispst,ias,ig), 1, &
                          wftmp1( (ias-1)*nmt+1, ig ), 1 )
           END DO ! ias
        END DO ! ig

#if defined(_DEBUG_megqblh_) && EBUG >= 3
        dbgcnt2 = 0
#endif /* _DEBUG_megqblh_ */

        ! The starting point of the index "i" for accessing bmegqblh(:,i,:)
        ! for each iband and ikloc was stored as idxtranblhloc
        ! Note that spinstidx stores the band indices for a single spin projection
        iband = spinstidx( ispst )
        i = idxtranblhloc( iband, ikloc )
        ist1 = bmegqblh(1,i,ikloc)

!--end Convert to true ZGEMM

! interstitial part
#if EBUG >= 3
        WRITE(*,*) 'genmegqblh: ngknr1=', ngknr1, ' ngknr2=', ngknr2
#endif /* DEBUG */

        call papi_timer_start(pt_megqblh_it)
        call timer_start(4)
        wfir1=zzero
        do ig1=1,ngknr1
           ifg=igfft(igkignr1(ig1))

#if EBUG >= 3
           WRITE(*,*) 'genmegqblh: ig1=', ig1, ' ifg=', ifg
#endif /* DEBUG */

           wfir1(ifg)=wfsvit1(ig1,ispn1,ist1)
        enddo
        call zfftifc(3,ngrid,1,wfir1)
        do ir=1,ngrtot
           wfir1(ir)=wfir1(ir)*cfunir(ir)
        enddo
        call zfftifc(3,ngrid,-1,wfir1)
        do ig=1,ngqiq
           do ig2=1,ngknr2
! G1=G2-G-Gkq
              ivg1(:)=ivg(:,igkignr2(ig2))-ivg(:,igqig(ig,iq))-ivg(:,igkq)
              ifg=igfft(ivgig(ivg1(1),ivg1(2),ivg1(3)))
              wftmp1(lmmaxapw*nufrmax*natmtot+ig2,ig)=dconjg(wfir1(ifg))
           enddo
        enddo
        call timer_stop(4)      
        call papi_timer_stop(pt_megqblh_it)

        call timer_start(5)

        ! Load number of matching |ist2=n'> ket states for each <ist1=n| bra
        ! Note: ntran should NOT be zero (even though the code provides
        ! a zero-trip loop for that case)
        ntran = ntranblhloc(iband,ikloc)

#if defined(_DEBUG_bmegqblh_) || defined(_DEBUG_megqblh_)
        IF( ntran > 0 ) THEN
           dbgcnt0 = dbgcnt0 + 1
           dbgcnt1 = dbgcnt1 + 1
#ifdef _DEBUG_bmegqblh_
           WRITE( dbgunit1, '(7(1X,I5))' ) dbgcnt1, ikloc, iq, iband, i, ntran, i+ntran-1
#endif /* _DEBUG_bmegqblh_ */
        ELSE
           WRITE(*,'(4(A,I4))') 'Warning(genmegqblh): ntran is not positive ikloc=', ikloc, ' iq=', iq, ' iband=', iband, ' ntran=', ntran
        END IF
#endif /* _DEBUG_bmegqblh_ || _DEBUG_megqblh_ */

#if EBUG >= 2
        WRITE(*,*) 'genmegqblh: ispst=', ispst, ' ntran=', ntran
#endif /* DEBUG */

#if defined(_DEBUG_megqblh_) && EBUG >= 3
        dbgcnt2 = 0
#endif /* _DEBUG_megqblh_ */

! collect right |ket> states into matrix wftmp2

        DO n1 = 1, ntran

           ist2 = bmegqblh(2,i+n1-1,ikloc) ! Now n1 starts from 1 instead of 0

#if defined(_DEBUG_megqblh_) && EBUG >= 3
           dbgcnt2 = dbgcnt2 + 1
           WRITE(*,*) 'genmegqblh: iproc=', iproc, ' ikloc=', ikloc, ' iq=', iq, &
                                  'ispn1=', ispn1, 'j=', ist1, ' ispn2=', ispn2, " j'=", ist2
#endif /* _DEBUG_megqblh_ */

           ! Following Ed's advice, use ZCOPY() from BLAS instead of memcopy
           ! TODO: check whether it's better to transfer all in one go
           !       or overlap computation & data movement

           ! Muffin tin
           CALL zcopy( nmt*natmtot, &
                       wfsvmt2(1,1,1,ispn2,ist2), 1, &
                       wftmp2(1,n1), 1 )
           ! Interstitial
           CALL zcopy( ngknr2, &
                       wfsvit2(1,ispn2,ist2), 1, &
                       wftmp2(nmt*natmtot+1,n1), 1 )

        END DO ! n1; replaced do while loop (i+n1) <= nmegqblh(ikloc)

#if defined(_DEBUG_megqblh_) && EBUG >= 3
        WRITE(*,*) 'genmegqblh: iproc=', iproc, ' ikloc=', ikloc, ' iq=', iq, &
                   ' for j=', ist1, " N_j'=", dbgcnt2
#endif /* _DEBUG_megqblh_ */

! update several matrix elements by doing matrix*matrix operation
!  me(ib,ig)=wftmp2(ig2,ib)^{T}*wftmp1(ig2,ig)

        ! This particular ZGEMM() call corresponds with line 9 of Algorithm 2
        ! in the Gordon Bell paper
        ! If available, use the 3M algorithm
#ifdef  _USE_3M_
#if EBUG > 0
        WRITE(*,*) 'zgemm3m: m =', ntran, ' n = ', ngqiq, 'k = ', wfsize
#endif /* DEBUG */
        CALL ZGEMM3M( 'T', 'N', ntran, ngqiq, wfsize, &
                      zone, wftmp2, wfsize, &
                            wftmp1, wfsize, &
                      zone, megqblh(i,1,ikloc), nstsv**2 )
#else
#if EBUG > 0
        WRITE(*,*) 'zgemm: m =', ntran, ' n = ', ngqiq, 'k = ', wfsize
#endif /* DEBUG */
        CALL ZGEMM( 'T', 'N', ntran, ngqiq, wfsize, &
                    zone, wftmp2, wfsize, &
                          wftmp1, wfsize, &
                    zone, megqblh(i,1,ikloc), nstsv**2 )
#endif /* _USE_3M_ */

        ! No need to add n1 to i anymore to move on to the next <nk| bra
        ! since it is already stored as ntranblhloc

        CALL timer_stop(5) ! Same as before

     END DO ! ispst; replaces do while loop i <= nmegqblh(ikloc)

#ifdef _DEBUG_bmegqblh_
     WRITE( dbgunit1, '(A,I3)') 'highest band = ', iband
#endif /* _DEBUG_bmegqblh_ */

     ! Clean up
     CALL genmegqblh_freemodvar_mt
     CALL genmegqblh_freemodvar_spin

!--end Convert do while into bounded do loop

#if defined(_DEBUG_megqblh_) && EBUG >= 3
     WRITE(*,*) 'genmegqblh: iproc=', iproc, ' ikloc=', ikloc, ' iq=', iq, &
                ' for ispn1=', ispn1, ' N_j=', dbgcnt1
#endif /* _DEBUG_megqblh_ */

  END DO ! ispn1

#if defined(_DEBUG_megqblh_) && EBUG >= 3
     WRITE(*,*) 'genmegqblh: iproc=', iproc, ' ikloc=', ikloc, ' iq=', iq, &
                ' total N_j=', dbgcnt0
#endif /* _DEBUG_megqblh_ */

  ! Clean up
  CALL genmegqblh_freemodvar_const

  ! wfsize, ngknr2
  ! !$ACC END DATA

  ! Clean up CPU arrays
  DEALLOCATE( wftmp1 )
  DEALLOCATE( wftmp2 )
  DEALLOCATE( wfir1 )

  call papi_timer_stop(pt_megqblh)

  return
end subroutine genmegqblh
