!----------------------------------------------------------------------------
! This file is part of UCLALES.
!
! UCLALES is free software; you can redistribute it and/or modify
! it under the terms of the GNU General Public License as published by
! the Free Software Foundation; either version 3 of the License, or
! (at your option) any later version.
!
! UCLALES is distributed in the hope that it will be useful,
! but WITHOUT ANY WARRANTY; without even the implied warranty of
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
! GNU General Public License for more details.
!
! You should have received a copy of the GNU General Public License
! along with this program.  If not, see <http://www.gnu.org/licenses/>.
!
! Copyright 1999-2008, Bjorn B. Stevens, Dep't Atmos and Ocean Sci, UCLA
!----------------------------------------------------------------------------
!
! This is an adaptation from the original Independent Pixel Code.
! In the IPA Code the spatial dimensions are the outermost loops.
! To allow for 3D approximations and solvers, we need to rearrange the loop structure,
! so that the spectral integration is outermost.
! The 1D routines are reused as much as possible to guarantee conformance to earlier results.
! The 3D interface can be called with iradtype:
! 6 -- 1D original delta 4 stream solver
! 7 -- thermal and solar tenstream solver
! The copying of the optical properties fields results in a performance penalty 
! -- hence if you do not use a 3D solver, please use the 1D interface with iradtype=4

module radiation_3d

  use grid, only       : nzp,nxp,nyp, deltax,deltay,zm
  use grid, only       : xm,ym !TODO DEBUG
  use fuliou, only     : minSolarZenithCosForVis
  use mpi_interface, only : myid,ierror
  use radiation, only  : zenith, setup, pp, pt, ph,po, plwc, pre, prwc, piwc, pde, pgwc, &
      u0, fixed_sun, radMcICA, rad_eff_radius !namelist parameters

#ifdef HAVE_TENSTREAM
      use mpi_interface, only: nxpa,nypa
      use mpi, only : MPI_COMM_WORLD
      use m_tenstream, only: init_tenstream,set_optical_properties,solve_tenstream, destroy_tenstream, tenstream_get_result, need_new_solution
      use m_data_parameters, only : ireals,iintegers
      use grid, only : dt,nstep
#endif      

  implicit none

  private 
  public :: rad_3d

  character (len=10), parameter :: background = 'backrad_in'

  !those global vars are in radiation module...  ::  pp, pt, ph, po, pre, pde, plwc, piwc, prwc, pgwc
  real,parameter :: zero=0, one=1

  integer :: npts
  real    :: ee, day, time, alat, zz
  integer :: is,ie,js,je

  logical,save :: linit=.False.
  logical,parameter :: ldebug=.False.
!  logical,parameter :: ldebug=.True.

#ifdef HAVE_TENSTREAM
  integer(iintegers) :: solution_uid    ! is solution uid, each subband has one
  real(ireals)       :: solution_time   ! is set to the approximate time of each solve
#endif

contains

  subroutine rad_3d(alat, time, sknt, sfc_albedo, CCN, dn0, &
          pi0, pi1, pip, th, rv, rc, tt, rflx, sflx ,lflxu, lflxd,sflxu,sflxd, &
          albedo, lflxu_toa, lflxd_toa, sflxu_toa, sflxd_toa, rr,ice,nice,grp)
!      use defs,only:nv1!TODO need only for debugging

      real, intent (in)    :: alat, time, sknt, sfc_albedo, CCN
      real, dimension (nzp), intent (in)                   :: dn0, pi0, pi1
      real, dimension (nzp,nxp,nyp), intent (in)           :: pip, th, rv, rc
      real, optional, dimension (nzp,nxp,nyp), intent (in) :: rr,ice,nice,grp
      real, dimension (nzp,nxp,nyp), intent (inout)        :: tt, rflx, sflx, lflxu, lflxd, sflxu, sflxd
      real, dimension (nxp,nyp), intent (out),optional     :: albedo, lflxu_toa, lflxd_toa, sflxu_toa, sflxd_toa

      real,allocatable,dimension(:,:,:) :: fus,fds,fdiv_sol,flxdiv
      real,allocatable,dimension(:,:,:) :: fuir,fdir,fdiv_th

      real,allocatable,dimension(:,:,:) :: hr_factor ! convert from flux divergence to heating rate

      real :: p0(nzp)

      integer i,j,k,kk

      if(myid.eq.0.and.ldebug) print *,'calculate radiation',u0,'xm',xm,'ym',ym
      if(ldebug) print *,myid,'calculate radiation xm',xm,'ym',ym

      call init_rad_3d()

      call solar_rad()
      call thermal_rad()

!      do k=1,nv1
!        if(myid.le.0) print *,k,'solar',fds(k,3,3),fus(k,3,3),':: thermal',fdir(k,3,3),fuir(k,3,3)
!      enddo
      !copy from radiation grid, to dynamics grid
      do k=1,nzp
        kk = ubound(fus,1) - (k-1)
        sflx(k,is:ie,js:je) = fus(kk,:,:)  - fds(kk,:,:)
        !irina
        sflxu(k,is:ie,js:je)=fus (kk,:,:)
        sflxd(k,is:ie,js:je)=fds (kk,:,:)
        lflxu(k,is:ie,js:je)=fuir(kk,:,:)
        lflxd(k,is:ie,js:je)=fdir(kk,:,:)

        rflx  (k,is:ie,js:je) = sflx    (k ,is:ie,js:je) + fuir(kk,:,:) - fdir(kk,:,:)
        flxdiv(k,is:ie,js:je) = fdiv_sol(kk,is:ie,js:je) + fdiv_th(kk,is:ie,js:je)
      end do

      if (present(albedo)) then
        if (u0 > minSolarZenithCosForVis) then
          albedo(is:ie,js:je) = fus(1,:,:)/fds(1,:,:)
        else
          albedo = -999.
        end if
      end if

      if (present(sflxu_toa)) then
        if (u0 > minSolarZenithCosForVis) then
          sflxu_toa(is:ie,js:je) = fus(1,:,:)
        else
          sflxu_toa(is:ie,js:je) = -999.
        end if
      end if
      if (present(sflxd_toa)) then
        if (u0 > minSolarZenithCosForVis) then
          sflxd_toa(is:ie,js:je) = fds(1,:,:)
        else
          sflxd_toa(is:ie,js:je) = -999.
        end if
      end if
      if (present(lflxu_toa)) then
        lflxu_toa(is:ie,js:je) = fuir(1,:,:)
      end if
      if (present(lflxd_toa)) then
        lflxd_toa(is:ie,js:je) = fdir(1,:,:)
      end if
      !TODO here the loop was truncated to 'nzp-3' in the original code -- why not use heating rate in every layer?!?
      do k=2,nzp-3
        tt(k,is:ie, js:je) = tt(k, is:ie, js:je) + flxdiv(k,:,:)*hr_factor(k, :,:)
        if(ldebug) then
          if(any(isnan(rflx     (k,:,:)))) print *,myid,'nan in radiation tendency rflx  ',k,rflx    (k,:,:)
          if(any(isnan(fdiv_sol (k,:,:)))) print *,myid,'nan in radiation tendency divsol',k,fdiv_sol(k,:,:)
          if(any(isnan(fdiv_th  (k,:,:)))) print *,myid,'nan in radiation tendency divth ',k,fdiv_th (k,:,:)
          if(any(isnan(hr_factor(k,:,:)))) print *,myid,'nan in radiation tendency hrf',k,hr_factor(k,:,:)
          if(any(isnan(flxdiv   (k,:,:)))) print *,myid,'nan in radiation tendency div',k,flxdiv   (k,:,:)
          if(any(isnan(tt       (k,:,:)))) print *,myid,'nan in radiation tendency tt',k,tt(k,:,:)
          if(any(isnan([hr_factor(k,:,:),flxdiv(k,:,:),tt(k,:,:),fdiv_sol (k,:,:),fdiv_th  (k,:,:),rflx     (k,:,:)]))) call exit(1)
        endif
        !        i=3
        !        j=3
        !        if(myid.le.0) print *,'flx ::',k,' edn',lflxd(k,i,j),' eup',lflxu(k,i,j)
        !        if(myid.le.0) print *,'div ::',k,' sol',fdiv_sol(kk,i,j),' th',fdiv_th(kk,i,j)
        !        if(myid.le.0) print *,'flx ::',k,' flxdiv',flxdiv(k,i,j),'tt',tt(k,i,j)
        !        if(myid.le.0) print *,'heating rate ::',k,flxdiv(k,i,j),  hr_factor(k,i,j), - (rflx(k,i,j) - rflx(k-1,i,j))
!        if(myid.le.0) print *,k,'solar',sflxd(k,3,3),sflxu(k,3,3),':: thermal',lflxd(k,3,3),lflxu(k,3,3)
      end do

      if(myid.eq.0.and.ldebug) print *,'calculate radiation ... done'
    contains
      subroutine thermal_rad()
          use grid, only       : iradtyp
          use ckd   , only: llimit, rlimit
          use fuliou, only: computeIRBandWeights, planck, select_bandg
          use defs, only: nv,nv1,pi
          use solver, only : qft
          use ckd, only: ir_bands,gPointWeight,kg

          real,dimension(nv1)  :: fu1,fd1
          real,dimension(nv1,  is:ie,js:je) :: fd3d,fu3d,fdiv3d
          real,dimension(nv ,  is:ie,js:je) :: tau,w0,dz
          real,dimension(nv ,4,is:ie,js:je) :: phasefct

          real,dimension(nv1,  is:ie,js:je) :: bf

          real, dimension(:), allocatable, save :: bandWeights

          real :: fuq2,xir_norm
          logical, parameter :: irWeighted = .False.

          real    :: randomNumber

          integer :: iband, igpt,nrbands,nrgpts, ib, ig
          integer :: ibandloop(3:nxp-2, 3:nyp-2), ibandg(3:nxp-2, 3:nyp-2) ! for McICA, save wavelength band information for each pixel
          real    :: exner(nzp), pres(nzp)

#ifdef HAVE_TENSTREAM
          real(ireals),dimension(:,:,:),allocatable :: edn,eup
          real(ireals),dimension(:,:,:),allocatable :: abso
          solution_uid = 500
#endif

          fdir    = 0 
          fuir    = 0 
          fdiv_th = 0 

          if (.not. allocated(bandweights)) then 
            allocate(bandweights(size(ir_bands)))
            call computeIRBandWeights(ir_bands, irWeighted, bandWeights)
          end if

          if (radMcICA) then
            do j=js,je
              do i=is,ie
                call random_number(randomNumber)
                !
                ! Select a single band and g-point (ib, ig1) and use these as the 
                ! limits in the loop through the spectrum below. 
                !
                call select_bandg(ir_bands, bandweights, randomNumber, ib, ig)
                ibandloop(i,j) = ib
                ibandg   (i,j) = ig
                nrbands = 1
                nrgpts  = 1
              enddo 
            enddo
          else
            nrbands = size(ir_bands)
          end if
          do iband = 1, nrbands
            if(.not.radMcICA) nrgpts = kg(ir_bands(iband))
            do igpt = 1, nrgpts
              if(myid.eq.0.and.ldebug) print *,myid,'DEBUG :: calculating thermal band',iband,igpt    !TODO

              ib = iband
              ig = igpt

#ifdef HAVE_TENSTREAM
              solution_uid=solution_uid+1
              solution_time = time*3600._ireals*24._ireals + dt*(nstep-1._ireals)/3._ireals !time is given in days + approx. a third at each rungekutta step
              if(.not.need_new_solution(solution_uid,solution_time)) then
                allocate(edn (3:nxp-2,3:nyp-2,nv+1))
                allocate(eup (3:nxp-2,3:nyp-2,nv+1))
                allocate(abso(3:nxp-2,3:nyp-2,nv  ))
                call tenstream_get_result(redn=edn,reup=eup,rabso=abso)
                do k=1,nv
                  fd3d  (k,:,:) = edn (:,:,k)
                  fu3d  (k,:,:) = eup (:,:,k)
                  fdiv3d(k,:,:) = abso(:,:,k) * dz(k,:,:)
                enddo
                deallocate(abso)

                fd3d  (nv+1,:,:) = edn(:,:,nv+1)
                fu3d  (nv+1,:,:) = eup(:,:,nv+1)
                fdiv3d(nv+1,:,:) = edn(:,:,nv+1) - eup(:,:,nv+1)

                deallocate(edn )
                deallocate(eup )
                cycle
              endif
#endif

              do j=js,je
                do i=is,ie

                  if(radMcICA) then
                    ib = ibandloop(i,j)
                    ig = ibandg   (i,j)
                  endif

                  if (present(ice).and.present(grp)) then
                    call setup_rad_atmosphere(CCN, dn0, pi0, pi1,    &
                        pip(:,i,j), th(:,i,j), rv(:,i,j), rc(:,i,j), &
                        exner,pres,  hr_factor(:,i,j),               &
                        rr=rr(:,i,j),ice=ice(:,i,j),nice=nice(:,i,j),grp=grp(:,i,j))

                    call optprop_rad_ir( ib, ig, pp, pt, ph, po, &
                        tau (:,i,j), w0  (:,i,j), phasefct(:,:,i,j), dz(:,i,j), & 
                        plwc=plwc, pre=pre, piwc=piwc, pde=pde, pgwc=pgwc)
                  else

                    call setup_rad_atmosphere(CCN, dn0, pi0, pi1,    &
                        pip(:,i,j), th(:,i,j), rv(:,i,j), rc(:,i,j), &
                        exner,pres, hr_factor(:,i,j)                 )


                    call optprop_rad_ir( ib, ig, pp, pt, ph, po,&
                        tau (:,i,j), w0  (:,i,j), phasefct(:,:,i,j), dz(:,i,j), & 
                        plwc=plwc, pre=pre)
                  end if

                  call planck(pt, sknt, llimit(ir_bands(ib)), rlimit(ir_bands(ib)), bf(:,i,j))

                end do ! j
              end do ! i


              select case(iradtyp)

              case (6) ! d4stream with 3d interface

                do j = js, je  
                  do i = is, ie  

                    ! Solver expects cumulative optical depth
                    do k = 2, nv
                      tau(k,i,j) = tau(k, i,j) + tau(k-1, i,j)
                    end do
                    call qft (.false., ee, zero, zero, bf(:,i,j), tau(:,i,j), w0(:,i,j), &   ! thermal qft
                        phasefct(:, 1, i,j), phasefct(:, 2, i,j),    &
                        phasefct(:, 3, i,j), phasefct(:, 4, i,j), fu1, fd1)
!                    if(ib.eq.2 .and. myid.eq.0 .and. i.eq.3 .and. j.eq.3) then
!                      do k=1,nv1
!                        print *,'tenstr edn',fd1(k),fu1(k),bf(k,3,3),'::',fdir(k,i,j),fuir(k,i,j)
!                      enddo
!                      call exit(1)
!                    endif

                    xir_norm = gPointWeight(ir_bands(ib), ig)

                    if (radMcICA) then
                      ib = ibandloop(i,j)
                      ig = ibandg   (i,j)
                      xir_norm = 1./bandweights(ib)
                    end if

                    fdir(:,i,j) = fdir(:,i,j) + fd1(:) * xir_norm 
                    fuir(:,i,j) = fuir(:,i,j) + fu1(:) * xir_norm 
                  end do ! i
                end do ! j
                fdiv_th(1:nv,:,:) = (fdir(1:nv,:,:) - fuir(1:nv,:,:)) + (fuir(2:nv1,:,:) - fdir(2:nv1,:,:))
                fdiv_th( nv1,:,:) = (fdir( nv1,:,:) - fuir(nv1,:,:))

              case (7) !tenstr
#ifdef HAVE_TENSTREAM
                call tenstream_wrapper(.False., nxp,nyp,nv,deltax,deltay,dz, -one,-one, one-ee,zero, tau, w0, phasefct,bf, fd3d,fu3d,fdiv3d)
#else
                print *,'This build does not support the tenstream solver ... exiting!'
                call exit(1)
#endif

                if (radMcICA) then
                  do j = js, je  
                    do i = is, ie  
                      ib = ibandloop(i,j)
                      xir_norm = 1./bandweights(ib)
                      fd3d  (:,i,j) = fd3d  (:,i,j)*xir_norm
                      fu3d  (:,i,j) = fu3d  (:,i,j)*xir_norm
                      fdiv3d(:,i,j) = fdiv3d(:,i,j)*xir_norm
                    end do ! i
                  end do ! j
                else
                  xir_norm = gPointWeight(ir_bands(ib), ig)
                  fd3d  = fd3d  *xir_norm
                  fu3d  = fu3d  *xir_norm
                  fdiv3d= fdiv3d*xir_norm
                end if
                fdir = fdir       + fd3d  
                fuir = fuir       + fu3d  
                fdiv_th = fdiv_th + fdiv3d
              end select

            enddo !igpt
          enddo !iband

          !
          ! fuq2 is the surface emitted flux in the band 0 - 280 cm**-1 with a
          ! hk of 0.03. !TODO Fabian: what exactly does this mean?
          !
          do j = js, je  
            do i = is, ie  
              fuq2 = bf(nv1,i,j) * 0.03 * pi * ee
              fuir(:,i,j) = fuir(:,i,j) + fuq2
            end do ! i
          end do ! j

      end subroutine
      subroutine solar_rad()
          use grid, only   : iradtyp
          use defs, only   : nv,nv1,SolarConstant,totalpower
          use solver, only : qft
          use fuliou, only : computesolarbandweights, select_bandg
          use ckd, only    : solar_bands,kg,power,gPointWeight
          use mpi, only    : mpi_comm_world,mpi_barrier !TODO

!          use m_twostream, only: delta_eddington_twostream

          real :: fuq1,xs_norm
          real,dimension(nv1)  :: fu1,fd1
          real,dimension(nv1,  is:ie,js:je) :: fu3d,fd3d,fdiv3d
          real,dimension(nv ,  is:ie,js:je) :: tau,w0,dz
          real,dimension(nv1,  is:ie,js:je) :: bf
          real,dimension(nv ,4,is:ie,js:je) :: phasefct
          real, dimension(:), allocatable, save :: bandWeights

          real    :: randomNumber
          logical, parameter :: solarWeighted = .true. 

          integer :: iband, igpt,nrbands,nrgpts, ib, ig
          integer :: ibandloop(3:nxp-2, 3:nyp-2), ibandg(3:nxp-2, 3:nyp-2) ! for McICA, save wavelength band information for each pixel
          real    :: exner(nzp), pres(nzp)

#ifdef HAVE_TENSTREAM
          real(ireals),dimension(:,:,:),allocatable :: edir,edn,eup
          real(ireals),dimension(:,:,:),allocatable :: abso
          solution_uid = 1
#endif

          fus      = zero
          fds      = zero
          fdiv_sol = zero

          if(u0.le.minSolarZenithCosForVis) then
            return
          endif

          if (.not. allocated(bandweights)) then 
            allocate(bandweights(size(solar_bands)))
            call computeSolarBandWeights(solar_bands, solarWeighted, bandWeights)
          end if

          if (radMcICA) then
            do j=js,je
              do i=is,ie
                call random_number(randomNumber)
                !
                ! Select a single band and g-point (ib, ig1) and use these as the 
                ! limits in the loop through the spectrum below. 
                !
                call select_bandg(solar_bands, bandweights, randomNumber, ib, ig)
                ibandloop(i,j) = ib
                ibandg   (i,j) = ig
                nrbands = 1
                nrgpts  = 1
              enddo 
            enddo
          else
            nrbands = size(solar_bands)
          end if
          do iband = 1, nrbands
            if(.not.radMcICA) nrgpts = kg(solar_bands(iband))
            do igpt = 1, nrgpts
              if(myid.eq.0.and.ldebug) print *,myid,'DEBUG :: calculating solar band',iband,igpt    !TODO
              ib = iband
              ig = igpt

#ifdef HAVE_TENSTREAM
              solution_uid=solution_uid+1
              solution_time = time*3600._ireals*24._ireals + dt*(nstep-1._ireals)/3._ireals !time is given in days + approx. a third at each rungekutta step
              if(.not.need_new_solution(solution_uid,solution_time)) then

                allocate(edn (3:nxp-2,3:nyp-2,nv+1))
                allocate(eup (3:nxp-2,3:nyp-2,nv+1))
                allocate(abso(3:nxp-2,3:nyp-2,nv  ))
                allocate(edir(3:nxp-2,3:nyp-2,nv+1))
                call tenstream_get_result(redir=edir,redn=edn,reup=eup,rabso=abso)
                do k=1,nv
                  fd3d  (k,:,:) = edn (:,:,k) + edir(:,:,k)
                  fu3d  (k,:,:) = eup (:,:,k)
                  fdiv3d(k,:,:) = abso(:,:,k) * dz(k,:,:)
                enddo
                deallocate(abso)

                fd3d  (nv+1,:,:) = edn(:,:,nv+1) + edir(:,:,nv+1)
                fu3d  (nv+1,:,:) = eup(:,:,nv+1)
                fdiv3d(nv+1,:,:) = edn(:,:,nv+1) - eup(:,:,nv+1)

                deallocate(edir)
                deallocate(edn )
                deallocate(eup )
                cycle
              endif
#endif

              do j=js,je
                do i=is,ie

                  if(radMcICA) then
                    ib = ibandloop(i,j)
                    ig = ibandg   (i,j)
                  endif

                  if (present(ice).and.present(grp)) then
                    call setup_rad_atmosphere(CCN, dn0, pi0, pi1,    &
                        pip(:,i,j), th(:,i,j), rv(:,i,j), rc(:,i,j), &
                        exner,pres, hr_factor(:,i,j),                &
                        rr=rr(:,i,j),ice=ice(:,i,j),nice=nice(:,i,j),grp=grp(:,i,j))

                    call optprop_rad_vis( ib, ig, pp, pt, ph, po, &
                        tau (:,i,j), w0  (:,i,j), phasefct(:,:,i,j), dz(:,i,j), & 
                        plwc=plwc, pre=pre, piwc=piwc, pde=pde, pgwc=pgwc)
                  else

                    call setup_rad_atmosphere(CCN, dn0, pi0, pi1,    &
                        pip(:,i,j), th(:,i,j), rv(:,i,j), rc(:,i,j), &
                        exner,pres, hr_factor(:,i,j)                 )


                    call optprop_rad_vis( ib, ig, pp, pt, ph, po,&
                        tau (:,i,j), w0  (:,i,j), phasefct(:,:,i,j), dz(:,i,j), & 
                        plwc=plwc, pre=pre)
                  end if

                  bf(:,i,j) = 0 ! no thermal emission in solar spectral range
                end do ! j
              end do ! i

              select case(iradtyp)

              case (6) ! d4stream with 3d interface

                do j = js, je  
                  do i = is, ie  

                    ! Solver expects cumulative optical depth
                    do k = 2, nv
                      tau(k,i,j) = tau(k, i,j) + tau(k-1, i,j)
                    end do
                    call qft (.true., zero, sfc_albedo, u0, bf(:,i,j), tau(:,i,j), w0(:,i,j), &   ! Solar qft
                        phasefct(:, 1, i,j), phasefct(:, 2, i,j),    &
                        phasefct(:, 3, i,j), phasefct(:, 4, i,j), fu1, fd1)

                    if (radMcICA) then
                      xs_norm = power(solar_bands(ibandloop(i,j) ))/ bandweights(ibandloop(i,j))
                    else
                      xs_norm = gPointWeight(solar_bands(iband), igpt)*power(solar_bands(iband))
                    end if
                    fds(:,i,j) = fds(:,i,j) + fd1(:) * xs_norm 
                    fus(:,i,j) = fus(:,i,j) + fu1(:) * xs_norm 
                  end do ! i
                end do ! j
                fdiv_sol(1:nv,:,:) = (fds(1:nv,:,:) - fus(1:nv,:,:)) + (fus(2:nv1,:,:) - fds(2:nv1,:,:))
                fdiv_sol( nv1,:,:) = (fds(nv1,:,:) - fus(nv1,:,:))


              case (7) !tenstr
                xs_norm = gPointWeight(solar_bands(iband), igpt)*power(solar_bands(iband))

#ifdef HAVE_TENSTREAM
                call tenstream_wrapper(.True., nxp,nyp,nv,deltax,deltay,dz, zero,u0, sfc_albedo,xs_norm, tau, w0, phasefct,bf, fd3d,fu3d,fdiv3d)
#else
                print *,'This build does not support the tenstream solver ... exiting!'
                call exit(1)
#endif

                if (radMcICA) then
                  print *,'ATTENTION :: this is probably not meaningful! You should not use radMcICA together with 3d solvers'
                  call exit()
                !  do j = js, je  
                !    do i = is, ie  
                !      xs_norm = power(solar_bands(ibandloop(i,j) ))/ bandweights(ibandloop(i,j))
                !      fd3d  (:,i,j) = fd3d  (:,i,j)*xs_norm
                !      fu3d  (:,i,j) = fu3d  (:,i,j)*xs_norm
                !      fdiv3d(:,i,j) = fdiv3d(:,i,j)*xs_norm
                !    end do ! i
                !  end do ! j
                !else
                !  fd3d   = fd3d   *xs_norm
                !  fu3d   = fu3d   *xs_norm
                !  fdiv3d = fdiv3d *xs_norm
                end if
                fds     = fds      + fd3d  
                fus     = fus      + fu3d  
                fdiv_sol= fdiv_sol + fdiv3d
              end select

              if(ldebug) then
                do k=1,nv1
                  if(any(isnan( fds     (k,:,:)))) print *,myid,'nan in radiation tendency rflx  ',k,fds     (k,:,:)
                  if(any(isnan( fus     (k,:,:)))) print *,myid,'nan in radiation tendency divsol',k,fus     (k,:,:)
                  if(any(isnan( fdiv_sol(k,:,:)))) print *,myid,'nan in radiation tendency divth ',k,fdiv_sol(k,:,:)
                  if(any(isnan( fdiv3d  (k,:,:)))) print *,myid,'nan in radiation tendency divth ',k,fdiv3d  (k,:,:)
                  call mpi_barrier(MPI_COMM_WORLD,ierror)
                  if(any(isnan([fds     (k,:,:),fus     (k,:,:),fdiv_sol(k,:,:),fdiv3d  (k,:,:)]))) call exit(1)
                enddo
              endif

            enddo !igpt
          enddo !iband

          !
          ! In this model, we used the solar spectral irradiance determined by
          ! Thekaekara (1973), and 1340.0 W/m**2 is the solar energy contained 
          ! in the spectral region 0.2 - 4.0 um., thus scale solar fluxes by
          ! fuq1
          !
          fuq1    = SolarConstant / totalpower
          fus  = fus *fuq1
          fds  = fds *fuq1
          fdiv_sol = fdiv_sol*fuq1
      end subroutine
      subroutine init_rad_3d
          use defs,only: p00,cp,cpr,nv,nv1
          use ckd,    only : init_ckd
          use cldwtr, only : init_cldwtr, init_cldice, init_cldgrp

          if(.not.linit) then
            is=3; ie=nxp-2
            js=3; je=nyp-2
            p0(nzp) = (p00*(pi0(nzp)/cp)**cpr) / 100.
            p0(nzp-1) = (p00*(pi0(nzp-1)/cp)**cpr) / 100.
            call setup(background,nzp,npts,nv1,nv,p0,pi0)
            linit = .True.
            if (allocated(pre))   pre(:) = 0.
            if (allocated(pde))   pde(:) = 0.
            if (allocated(piwc)) piwc(:) = 0.
            if (allocated(prwc)) prwc(:) = 0.
            if (allocated(plwc)) plwc(:) = 0.
            if (allocated(pgwc)) pgwc(:) = 0.

            !Initializations from file: rad_d4stream
            call init_ckd
            call init_cldwtr
            call init_cldice
            call init_cldgrp

          end if

          allocate( fus     (nv1, is:ie, js:je) ) ; fus=0
          allocate( fds     (nv1, is:ie, js:je) ) ; fds=0
          allocate( fdiv_sol(nv1, is:ie, js:je) ) ; fdiv_sol=0

          allocate( fuir    (nv1, is:ie, js:je) ) ; fuir=0
          allocate( fdir    (nv1, is:ie, js:je) ) ; fdir=0
          allocate( fdiv_th (nv1, is:ie, js:je) ) ; fdiv_th=0


          allocate( flxdiv(nzp, is:ie, js:je) )   ; flxdiv=0
          allocate( hr_factor(nzp, is:ie, js:je) ); hr_factor=0

          ! initialize surface albedo, emissivity and skin temperature.
          ee = 1.0

          ! determine the solar geometery, as measured by u0, the cosine of the
          ! solar zenith angle
          if (.not. fixed_sun) u0 = zenith(alat,time)

      end subroutine
  end subroutine rad_3d
  subroutine setup_rad_atmosphere(CCN, dn0, pi0, pi1, pip, th, rv, rc,     exner,pres,hr_fac, rr,ice,nice,grp)
      use grid, only: dzi_m
      use defs, only: cp,cpr,nv,nv1,p00,pi,roice,rowt
      real, intent(in) :: CCN
      real, dimension (nzp), intent (in)           :: dn0, pi0, pi1
      real, dimension (nzp), intent (in)           :: pip, th, rv, rc

      real,intent(out) :: exner(nzp), pres(nzp),hr_fac(nzp)
      !thos global vars are in radiation module...  ::  pp, pt, ph, po, pre, pde, plwc, piwc, prwc, pgwc

      real, optional, dimension (nzp), intent (in) :: rr,ice,nice,grp

      real :: prw, pri
      integer :: kk,k
      prw = (4./3.)*pi*rowt
      pri = (3.*sqrt(3.)/8.)*roice

      do k=1,nzp
        exner(k)= (pi0(k)+pi1(k)+pip(k))/cp
        pres(k) = p00 * (exner(k))**cpr
      end do
      pp(nv1) = 0.5*(pres(1)+pres(2)) / 100.
      do k=2,nzp
        kk = nv-(k-2)
        pt(kk) = th(k)*exner(k)
        ph(kk) = max(0.,rv(k))
        plwc(kk) = 1000.*dn0(k)*max(0.,rc(k))
        pre(kk)  = rad_eff_radius*1.e6*(plwc(kk)/(1000.*prw*CCN*dn0(k)))**(1./3.)
        pre(kk)=min(max(pre(kk),4.18),31.23)
        if (plwc(kk).le.0.) pre(kk) = 0.
        if (present(rr)) then
          prwc(kk) = 1000.*dn0(k)*rr(k)
        else
          prwc(kk) = 0.
        end if
        if (present(ice)) then
          piwc(kk) = 1000.*dn0(k)*ice(k)
          if (nice(k).gt.0.0) then
            pde(kk)  = 1.e6*(piwc(kk)/(1000.*pri*nice(k)*dn0(k)))**(1./3.)
            pde(kk)=min(max(pde(kk),20.),180.)
          else
            pde(kk)  = 0.0
          endif
        else
          piwc(kk) = 0.
          pde(kk) = 0.0
        end if
        if (present(grp)) then
          pgwc(kk) = 1000.*dn0(k)*grp(k)
        else
          pgwc(kk) = 0.
        end if
        if (k < nzp) pp(kk) = 0.5*(pres(k)+pres(k+1)) / 100.
      end do
      pp(nv-nzp+2) = pres(nzp)/100. - 0.5*(pres(nzp-1)-pres(nzp)) / 100.

      do k=2,nzp
        hr_fac(k)  = dzi_m(k)/(cp*dn0(k)*exner(k))
      enddo
  end subroutine

  !calc of optprop extracted from rad_ir:
  subroutine optprop_rad_ir( ibandloop, ibandg, pp, pt, ph, po, tau, w, pf, dz, plwc, pre, piwc, pde, pgwc)
      use cldwtr, only : cloud_water, cloud_ice, cloud_grp
      use fuliou, only : thicks, gascon, combineopticalproperties,gases
      use ckd, only: ir_bands,solar_bands,center
      integer, intent(in) :: ibandloop,ibandg

      real, intent (in)  :: pp (:) ! pressure at interfaces

      real, dimension(:), intent (in)  :: &
          pt,   & ! temperature [K] at mid points
          ph,   & ! humidity mixing ratio in kg/kg
          po      ! ozone mixing ratio
      real, dimension(:)  , intent(out) :: tau,w,dz ! dim: (nv)
      real, dimension(:,:), intent(out) :: pf       ! dim: (nv,4)

      real, optional, dimension(:), intent (in)  :: & ! dim: (nv)
          plwc, & ! cloud liquid water content [g/m^3]
          pre,  & ! effective radius of cloud droplets [microns]
          piwc, & ! cloud ice water content [g/m^3]
          pde,  & ! effective diameter of ice particles [microns]
          pgwc    ! graupel water content

      ! ----------------------------------------

      real, dimension (size(tau))   :: tw,ww,tg, tauNoGas, wNoGas
      real, dimension (size(tau))   :: ti,wi
      real, dimension (size(tau))   :: tgr,wgr
      real, dimension (size(tau),4) :: www, pfNoGas
      real, dimension (size(tau),4) :: wwi
      real, dimension (size(tau),4) :: wwgr

      integer :: ib, ig,k
      ! ----------------------------------------
      tau=0
      w=0
      pf=0

      call thicks(pp, pt, ph, dz) 

      ib = ibandloop
      ig = ibandg

      ! Water vapor continuum optical depth
      !
      call gascon ( center(ir_bands(ib)), pp, pt, ph, TauNoGas )
      wNoGas = 0.; pfNoGas  = 0.
      if (present(plwc)) then
        call cloud_water(ib + size(solar_bands), pre, plwc, dz, tw, ww, www)
        call combineOpticalProperties(TauNoGas, wNoGas, pfNoGas, tw, ww, www)
      end if
      if (present(piwc)) then
        call cloud_ice(ib + size(solar_bands), pde, piwc, dz, ti, wi, wwi)
        call combineOpticalProperties(TauNoGas, wNoGas, pfNoGas, ti, wi, wwi)
      end if
      if (present(pgwc)) then
        call cloud_grp(ib + size(solar_bands), pgwc, dz, tgr, wgr, wwgr)
        call combineOpticalProperties(TauNoGas, wNoGas, pfNoGas, tgr, wgr, wwgr)
      end if

      tau = TauNoGas; w = wNoGas; pf = pfNoGas
      call gases (ir_bands(ib), ig, pp, pt, ph, po, tg )
      call combineOpticalProperties(tau, w, pf, tg)

      if(ldebug) then
        if(any(isnan([tau, w, pf]))) then
          do k=1,size(pt)
            print *,'DEBUG',k,'pp',pp(k),'pt',pt(k),'ph',ph(k),'dz',dz(k),'opt',tau(k), w(k), pf(k,:)
          enddo
          call exit(-1)
        endif
      endif
  end subroutine
  !calc of optprop extracted from rad_vis:
  subroutine optprop_rad_vis( ibandloop, ibandg, pp, pt, ph, po, tau, w, pf, dz, plwc, pre, piwc, pde, pgwc)
      use cldwtr, only : cloud_water, cloud_ice, cloud_grp
      use fuliou, only : thicks, rayle, gascon, combineopticalproperties,gases
      use ckd, only: solar_bands,power,center
      integer, intent(in) :: ibandloop,ibandg

      real, intent (in)  :: pp (:) ! pressure at interfaces

      real, dimension(:), intent (in)  :: &
          pt,   & ! temperature [K] at mid points
          ph,   & ! humidity mixing ratio in kg/kg
          po      ! ozone mixing ratio
      real, dimension(:)  , intent(out) :: tau,w,dz     ! dim: (nv)
      real, dimension(:,:), intent(out) :: pf           ! dim: (nv,4)

      real, optional, dimension(:), intent (in)  :: & ! dim: (nv)
          plwc, & ! cloud liquid water content [g/m^3]
          pre,  & ! effective radius of cloud droplets [microns]
          piwc, & ! cloud ice water content [g/m^3]
          pde,  & ! effective diameter of ice particles [microns]
          pgwc    ! graupel water content

      ! ----------------------------------------

      real, dimension (size(tau))   :: tw,ww,tg,tgm, tauNoGas, wNoGas
      real, dimension (size(tau))   :: ti,wi
      real, dimension (size(tau))   :: tgr,wgr
      real, dimension (size(tau),4) :: www, pfNoGas
      real, dimension (size(tau),4) :: wwi
      real, dimension (size(tau),4) :: wwgr

      integer :: ib, ig, k
      ! ----------------------------------------
      tau=0
      w  =0
      pf =0

      call thicks(pp, pt, ph, dz) 

      ib = ibandloop
      ig = ibandg

      !
      ! Rayleigh scattering
      !
      call rayle ( ib, u0, power(solar_bands(ib)), pp, pt, dz, tauNoGas, &
          wNoGas, pfNoGas)
      !
      ! Water vapor continuum
      !
      call gascon ( center(solar_bands(ib)), pp, pt, ph, tgm )
      if(any(tgm > 0.)) &
          call combineOpticalProperties(TauNoGas, wNoGas, pfNoGas, tgm)
      !
      ! Cloud water
      !
      if (present(plwc)) then
        call cloud_water(ib, pre, plwc, dz, tw, ww, www)
        call combineOpticalProperties(TauNoGas, wNoGas, pfNoGas, tw,ww,www)
      end if
      if (present(piwc)) then
        call cloud_ice(ib, pde, piwc, dz, ti, wi, wwi)
        call combineOpticalProperties(TauNoGas, wNoGas, pfNoGas, ti,wi,wwi)
      end if 
      if (present(pgwc)) then
        call cloud_grp(ib,pgwc, dz, tgr, wgr, wwgr)
        call combineOpticalProperties(TauNoGas, wNoGas, pfNoGas, tgr, wgr,wwgr)
      end if 

      tau = tauNoGas; w = wNoGas; pf = pfNoGas
      call gases (solar_bands(ib), ig, pp, pt, ph, po, tg )
      call combineOpticalProperties(tau, w, pf, tg)
      if(ldebug) then
        if(any(isnan([tau, w, pf]))) then
          do k=1,size(pt)
            print *,'DEBUG',k,'pp',pp(k),'pt',pt(k),'ph',ph(k),'dz',dz(k),'lwc',plwc(k),'opt',tau(k), w(k), pf(k,:)
          enddo
          call exit(-1)
        endif
      endif
  end subroutine

#ifdef HAVE_TENSTREAM
  subroutine tenstream_wrapper(lsolar, in_nxp,in_nyp,in_nv,in_dx,in_dy,dz, in_phi0,in_u0, in_albedo,in_incSolar, tau, w0, pf, bf, fdn,fup,fdiv)

      logical                ,intent(in) :: lsolar
      integer                ,intent(in) :: in_nxp,in_nyp,in_nv
      real                   ,intent(in) :: in_dx,in_dy,in_phi0,in_u0,in_albedo,in_incSolar
      real,dimension(:,:,:)  ,intent(in) :: tau,w0,dz,bf ! have dimensions (nv,nxp-4,nyp-4); bf with (nv1)
      real,dimension(:,:,:,:),intent(in) :: pf

      real,dimension(:,:,:),intent(out) :: fdn,fup,fdiv

      integer(iintegers) :: nxp,nyp,nv
      real(ireals) :: dx,dy,phi0,u0,albedo
      real(ireals),dimension(3:in_nxp-2,3:in_nyp-2,in_nv)   :: kabs,ksca,g,deltaz
      real(ireals),dimension(:,:,:),allocatable :: planck
      real(ireals),dimension(:,:,:),allocatable :: edir,edn,eup
      real(ireals),dimension(:,:,:),allocatable :: abso


      integer(iintegers) :: k
      real(ireals)       :: theta0,incSolar


      nxp=in_nxp;nyp=in_nyp;nv=in_nv
      dx=in_dx;dy=in_dy;phi0=in_phi0;u0=in_u0;albedo=in_albedo
      if(ldebug.and.myid.eq.0) print *,'Calling tenstream wrapper with lsolar',lsolar,'nx/ny',nxp,nyp

      if(lsolar .and. u0.gt.minSolarZenithCosForVis) then
        theta0=acos(u0)*180./3.141592653589793 !rad2deg
        incSolar = in_incSolar
      else
        theta0=0
        incSolar=0
      endif

      do k=1,nv
        deltaz(:,:,k) = dz (k,:,:)
        kabs  (:,:,k) = max(epsilon(kabs), tau(k,:,:)*(1.-w0(k,:,:)) / deltaz(:,:,k) )
        ksca  (:,:,k) = max(epsilon(ksca), tau(k,:,:)*    w0(k,:,:)  / deltaz(:,:,k) )
        g     (:,:,k) = pf (k,1,:,:)/3.
        if(ldebug) then
          if(any(isnan(kabs(:,:,k)))) print *,myid,'tenstream_wrapper :: corrupt kabs',kabs(:,:,k),'::',tau(k,:,:),'::',w0(k,:,:),'::',deltaz(:,:,k)
          if(any(isnan(ksca(:,:,k)))) print *,myid,'tenstream_wrapper :: corrupt ksca',ksca(:,:,k),'::',tau(k,:,:),'::',w0(k,:,:),'::',deltaz(:,:,k)
          if(any(isnan(g   (:,:,k)))) print *,myid,'tenstream_wrapper :: corrupt g   ',g   (:,:,k),'::',pf (k,1,:,:)                                      
        endif
      enddo
      if(.not. lsolar) then
        allocate(planck(3:nxp-2,3:nyp-2,nv+1))
        do k=1,nv+1
          planck(:,:,k) = bf (k,:,:)
        enddo
      endif

      call init_tenstream(MPI_COMM_WORLD, nxp-4,nyp-4,nv, dx,dy,phi0, theta0, albedo, nxproc=nxpa, nyproc=nypa,  dz3d=deltaz)
      if(lsolar) then
        call set_optical_properties( kabs, ksca, g )
      else
        call set_optical_properties( kabs, ksca, g, planck)
      endif

      call solve_tenstream(incSolar,solution_uid,solution_time)

      allocate(edn (3:nxp-2,3:nyp-2,nv+1))
      allocate(eup (3:nxp-2,3:nyp-2,nv+1))
      allocate(abso(3:nxp-2,3:nyp-2,nv  ))

      if(lsolar .and. u0.gt.minSolarZenithCosForVis) then
        allocate(edir(3:nxp-2,3:nyp-2,nv+1))
        call tenstream_get_result(redir=edir,redn=edn,reup=eup,rabso=abso)
        edn = edn+edir
        deallocate(edir)
      else
        call tenstream_get_result(redn=edn,reup=eup,rabso=abso)
      endif

      do k=1,nv
        fdn (k,:,:) = edn (:,:,k)
        fup (k,:,:) = eup (:,:,k)
        fdiv(k,:,:) = abso(:,:,k) * deltaz(:,:,k)
      enddo
      deallocate(abso)
    
      fdn (nv+1,:,:) = edn(:,:,nv+1)
      fup (nv+1,:,:) = eup(:,:,nv+1)
      fdiv(nv+1,:,:) = edn(:,:,nv+1) - eup(:,:,nv+1)

      deallocate(edn )
      deallocate(eup )

      if(ldebug) then
        if(any(isnan([fdn,fup,fdiv]))) then
          do k=1,nv+1
            print *,myid,'DEBUG',k,phi0, theta0,albedo
            print *,myid,'edn ::',fdn (k,:,:)
            print *,myid,'eup ::',fup (k,:,:)
            print *,myid,'div ::',fdiv(k,:,:)
          enddo
          call exit(-1)
        endif
      endif
  end subroutine
#endif
end module
