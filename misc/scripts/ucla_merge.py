#!/usr/bin/env python
import numpy as np
from netCDF4 import Dataset
import h5py as H
from glob import glob
import sys
import os

#--------------------------------------------------------------------------------------------------------------------------------
def write_nc(basename, data, dims):
  try:
    fname= basename+'.nc'
    if os.path.exists(fname):
      fmode='a'
    else:
      fmode='w'

    D=Dataset(fname,fmode)

    for dim in dims:
      if dim[0] not in D.dimensions: 
        D.createDimension(dim[0], len(dim[1]) )
        D.createVariable(dim[0] ,'f4',(dim[0],) )
        D.variables[dim[0]][:] = dim[1]

    D.createVariable(varname, 'f4', [ d[0] for d in dims ] , zlib=True,least_significant_digit=6, complevel=7)
    D.variables[varname][:] = data

  except Exception,e:
    print 'error occured when we tried writing data to netcdf file',e
  finally:
    D.close()

def exists_nc(basename, varname):
  try:
    fname= basename+'.nc'
    if os.path.exists(fname):
      fmode='r'
    else:
      return False

    D=Dataset(fname,fmode)

    if varname in D.variables:
      exists=True
    else:
      exists=False

  except Exception,e:
    print 'error occured when we checked if variable exists',e
    exists=False
  finally:
    if 'D' in locals(): D.close()
  return exists
#--------------------------------------------------------------------------------------------------------------------------------

maxtime=-1
#--------------------------------------------------------------------------------------------------------------------------------
def append_var(basename,varname):

  global maxtime
  if exists_nc(basename, varname):
    print "variable already exists",varname
    return

  files=glob(basename+'.0*.nc')

  if 'coord_files' not in locals(): coord_files={}
  for f in sorted(files):
        try:
          ident,coord,ending = f.split('.')
        except:
          try:
            ident,_,coord,ending = f.split('.')
          except:
            return -1

        x,y = ( int(coord[:4]), int(coord[4:]) )
        if (x,y) not in coord_files.keys(): coord_files[(x,y)] = { 'fname':f, }
#        print 'Addind to coords:',x,y

  nr_y = len(np.unique ([ k[1] for k in coord_files.keys() ]))
  nr_x = len(np.unique ([ k[0] for k in coord_files.keys() ]))


  for i in np.arange(nr_x):
    for j in np.arange(nr_y):

      D = Dataset(coord_files[(i,j)]['fname'] )

      print 'reading data from file:',coord_files[(i,j)]['fname'],' coords ',i,j

      l4d = len(D.variables[varname].dimensions[:])==4
      l3d = len(D.variables[varname].dimensions[:])==3
      l2d = len(D.variables[varname].dimensions[:])==2
      l1d = len(D.variables[varname].dimensions[:])==1

      if l4d: td,yd,xd,zd = D.variables[varname].dimensions[:]
      if l3d: td,yd,xd    = D.variables[varname].dimensions[:]
      if l2d: td,zd       = D.variables[varname].dimensions[:]
      if l1d: td,         = D.variables[varname].dimensions[:]

      if maxtime==-1:
        maxtime = len(D.variables[ td ][:])
        print 'maxtime is',maxtime

      if varname not in coord_files[(i,j)].keys(): 
        coord_files[(i,j)][varname] = D.variables[varname][:maxtime]

      print "Coords of variable:",varname,'::',D.variables[varname].dimensions[:],[l1d,l2d,l3d,l4d], np.shape( D.variables[varname] ), np.shape(coord_files[(i,j)][varname])

      coord_files[td] = D.variables[ td ][:maxtime]

      try:
        coord_files[zd] = D.variables[ zd ][:]
      except: # if there is no z axis, just use the indices
        if l4d: coord_files[zd] = np.arange( np.shape( D.variables[varname] )[3] )
        if l2d: coord_files[zd] = np.arange( np.shape( D.variables[varname] )[1] )

      if 'yd' in locals():
        if '%s.%s' % (yd,j) not in coord_files.keys(): 
          coord_files['%s.%s' % (yd,j)] = D.variables[ yd ][:maxtime] #save y-dimension

      if 'xd' in locals():
        if '%s.%s' % (xd,i) not in coord_files.keys():
          coord_files['%s.%s' % (xd,i)] = D.variables[ xd ][:maxtime] #save x-dimension

      D.close()

    # append individual arrays in y dimension
    if l3d or l4d: coord_files['concat_%s'%i] = np.concatenate( [ coord_files[(i,j)].pop(varname) for j in np.arange(nr_y) ], axis=1 )
    if l2d or l1d: coord_files['concat_%s'%i] = np.mean       ( [ coord_files[(i,j)].pop(varname) for j in np.arange(nr_y) ], axis=0 )

  # append individual arrays in x dimension
  if l3d or l4d: var = np.concatenate( [ coord_files.pop('concat_%s'%i) for i in np.arange(nr_x) ], axis=2)
  if l2d or l1d: var = np.mean       ( [ coord_files.pop('concat_%s'%i) for i in np.arange(nr_x) ], axis=0)

  # append coordinate arrays for x and y axis
  if 'yd' in locals(): coord_files[yd] = np.concatenate( [ coord_files.pop('%s.%s'%(yd,j)) for j in np.arange(nr_y) ], axis=1 ) 
  if 'xd' in locals(): coord_files[xd] = np.concatenate( [ coord_files.pop('%s.%s'%(xd,i)) for i in np.arange(nr_x) ], axis=2 ) 

  if l4d:
    data = var.swapaxes(2,3).swapaxes(1,2) # from [time,y,x,z] to [time,z,y,x]
    dims = [ [td,coord_files[td]], [zd,coord_files[zd]], [yd,coord_files[yd]], [xd,coord_files[xd]] ]
  if l3d:
    data = var.swapaxes(1,2) # from [time,y,x] to [time,y,x]
    dims = [ [td,coord_files[td]], [yd,coord_files[yd]], [xd,coord_files[xd]] ]
  if l2d:
    data = var
    dims = [ [td,coord_files[td]], [zd,coord_files[zd]] ]
  if l1d:
    data = var
    dims = [ [td,coord_files[td]], ]

  write_nc(basename, data, dims)
#--------------------------------------------------------------------------------------------------------------------------------

try:
  basename = str( sys.argv[1] )
except:
  sys.exit(-1)

for idim in [4,3,2,1]:
  try:
    varname = str( sys.argv[2] )
    vars = [varname, ]
  except:
    print "You did not specify a variable to convert.... I will try convert all vars"
    vars=[]
    D = Dataset( glob(basename+'.0*.nc')[0], 'r' )
    for v in D.variables:
      #      print 'Found Variable:',v.__str__()
      if len(D.variables[v].dimensions)>=idim: vars.append( v.__str__() )
    D.close()

  for varname in vars:
    append_var(basename,varname)
