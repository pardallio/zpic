#cython: language_level=3

cimport em1d
from libc.stdlib cimport calloc, free

import numpy as np
import sys
import time

cdef float custom_density( float x, void *f ):
	cdef Density d = <object> f
	return d.custom_func(x)

cdef class Density:
	"""Extension type to wrap t_density objects"""
	cdef t_density *_thisptr

	cdef object custom_func

	_density_types = {'uniform':UNIFORM,
	                  'step':STEP,
	                  'slab':SLAB,
	                  'ramp':RAMP,
	                  'custom':CUSTOM}

	def __cinit__( self, *, str type = 'uniform', float n = 1.0, float start = 0.0, float end = 0.0,
		           list ramp = [0.,0.], custom = None):

		# Allocates the structure and initializes all elements to 0
		self._thisptr = <t_density *> calloc(1, sizeof(t_density))

		self._thisptr.type = <density_type> self._density_types[type]
		self._thisptr.n = n
		self._thisptr.start = start
		self._thisptr.end = end
		self._thisptr.ramp = np.array(ramp, dtype=np.float32)
		if ( custom ):
			self.custom_func = custom
			self._thisptr.custom = custom_density
			self._thisptr.custom_data = <void *> self

	def __dealloc__(self):
		free( self._thisptr )

	def copy(self):
		new = Density()
		new.n	 = self.n
		new.type  = self.type
		new.start = self.start
		new.end   = self.end
		new.ramp  = self.ramp

		new.custom_func = self.custom_func
		new._thisptr.custom = self._thisptr.custom
		new._thisptr.custom_data = self._thisptr.custom_data

		return new

	@property
	def n(self):
		return self._thisptr.n

	@n.setter
	def n(self,value):
		self._thisptr.n = value

	@property
	def type(self):
		return self._thisptr.type

	@type.setter
	def type(self,value):
		self._thisptr.type = value

	@property
	def start(self):
		return self._thisptr.start

	@start.setter
	def start(self,value):
		self._thisptr.start = value

	@property
	def end(self):
		return self._thisptr.end

	@end.setter
	def end(self,value):
		self._thisptr.end = value

	@property
	def ramp(self):
		return self._thisptr.ramp

	@ramp.setter
	def ramp(self,value):
		self._thisptr.ramp = value

cdef class Species:
	"""Extension type to wrap t_species objects"""

	cdef t_species _this
	cdef t_species* _thisptr
	cdef Density _density
	cdef str _name

	# Diagnostic types
	_diag_types  = { 'charge':CHARGE, 'pha':PHA, 'particles':PARTICLES }
	_pha_quants = { 'x1':X1, 'u1':U1, 'u2':U2, 'u3':U3 }

	# Boundary condition types
	_bc_types = {'none':     PART_BC_NONE,
	             'periodic': PART_BC_PERIODIC,
	             'open':     PART_BC_OPEN }

	def __cinit__( self, str name, const float m_q, const int ppc, *,
				  list ufl = [0.,0.,0.], list uth = [0.,0.,0.], Density density = None):

		self._thisptr = &self._this
		self._name = name
		self._this.m_q = m_q
		self._this.ppc = ppc
		self._this.ufl = np.array(ufl, dtype=np.float32)
		self._this.uth = np.array(uth, dtype=np.float32)

		if ( density ):
			self._density = density.copy()
		else:
			# Use default uniform density
			self._density = Density()

	cdef new( self, t_species* ptr, int nx, float box, float dt ):
		self._thisptr = ptr
		spec_new( self._thisptr, self._name.encode(), self._this.m_q, self._this.ppc,
			self._this.ufl, self._this.uth,
			nx, box, dt, self._density._thisptr )

	cdef species_advance(self, t_emf* emf, t_current* current):
		spec_advance(self._thisptr,emf,current)

	def advance(self,sim):
		cdef EMF emf
		cdef Current current
		emf = sim.emf
		current=sim.current
		self.species_advance(emf._thisptr,current._thisptr)

	def report( self, str type, *, list quants = [], list pha_nx = [], list pha_range = [] ):
		cdef int _nx[2]
		cdef float _range[2][2]

		cdef int rep_type = self._diag_types[type]

		if ( rep_type == PHA ):
			# Phasespace diagnostics get special treatment
			_nx = np.array( pha_nx, dtype = np.int32)
			_range = np.array( pha_range, dtype = np.float32)
			rep_type = PHASESPACE( self._pha_quants[quants[0]],
				                   self._pha_quants[quants[1]])
			spec_report( self._thisptr, rep_type, _nx, _range )
		else:
			# Other diagnostic
			spec_report( self._thisptr, rep_type, NULL, NULL )


	@property
	def dx(self):
		return self._thisptr.dx

	@property
	def particles(self):
		cdef t_part[::1] buf = <t_part[:self._thisptr.np]>self._thisptr.part
		return np.asarray( buf )

	def charge(self):
		charge = np.zeros( shape = self._thisptr.nx+1, dtype = np.float32 )
		cdef float [::1] buf = charge
		spec_deposit_charge( self._thisptr, &buf[0] )

		# Throw away guard cell
		return charge[ 0 : self._thisptr.nx ]

	def phasespace( self, list quants, pha_nx, pha_range ):

		cdef int _nx[2]
		cdef float _range[2][2]
		cdef int rep_type = PHASESPACE( self._pha_quants[quants[0]],
				                        self._pha_quants[quants[1]])

		_nx = np.array( pha_nx, dtype = np.int32)
		_range = np.array( pha_range, dtype = np.float32)

		pha = np.zeros( shape = (_nx[1],_nx[0]), dtype = np.float32 )
		cdef float [:,:] buf = pha

		spec_deposit_pha( self._thisptr, rep_type, _nx, _range, &buf[0,0] )

		return pha

	@property
	def n_sort(self):
		return self._thisptr.dx

	@n_sort.setter
	def n_sort(self, int value):
		if ( value < 0 ):
			print("(*error*) Invalid value for n_sort, must be >= 0.", file = sys.stderr)
			return
		self._thisptr.n_sort = value



def phasespace( int a, int b ):
	"""Returns the type of the requested phasespace"""
	return PHASESPACE(a,b)


cdef class EMF:
	"""Extension type to wrap t_emf objects"""

	cdef t_emf* _thisptr

	# Diagnostic types
	_diag_types = { 'E' : EFLD,	'B' : BFLD }

	# Boundary condition types
	_bc_types = {'none':     EMF_BC_NONE,
	             'periodic': EMF_BC_PERIODIC,
	             'open':     EMF_BC_OPEN }

	# External field types
	_ext_fld_types = {'none'    : EMF_EXT_FLD_NONE,
	                  'uniform' : EMF_EXT_FLD_UNIFORM }

	cdef associate( self, t_emf* ptr ):
		self._thisptr = ptr

	def report( self, str type, char fc ):
		cdef int rep_type = self._diag_types[type];
		emf_report( self._thisptr, rep_type, fc )

	cdef emfld_advance(self, t_current* current):
		emf_advance(self._thisptr,current)

	def advance(self,sim):
		cdef Current current
		current=sim.current
		self.emfld_advance(current._thisptr)


	def get_energy( self ):
		cdef double energy[6]
		emf_get_energy( self._thisptr, energy )
		return np.array( energy, dtype = np.float64 )

	def set_ext_fld( self, str type, *, list E0 = None, list B0 = None ):
		cdef t_emf_ext_fld ext_fld;
		cdef float buf[3];

		ext_fld.type = self._ext_fld_types[type]

		if ( E0 ):
			buf = np.array( E0, dtype=np.float32)
			ext_fld.E0.x = buf[0]
			ext_fld.E0.y = buf[1]
			ext_fld.E0.z = buf[2]
		else:
			ext_fld.E0.x = 0
			ext_fld.E0.y = 0
			ext_fld.E0.z = 0

		if ( B0 ):
			buf = np.array( B0, dtype=np.float32)
			ext_fld.B0.x = buf[0]
			ext_fld.B0.y = buf[1]
			ext_fld.B0.z = buf[2]
		else:
			ext_fld.B0.x = 0
			ext_fld.B0.y = 0
			ext_fld.B0.z = 0

		emf_set_ext_fld( self._thisptr, &ext_fld )
	def prep_ext_fld(self):
		emf_prep_ext_fld( self._thisptr )
	@property
	def bc_type( self ):
		return self._thisptr.bc_type

	@bc_type.setter
	def bc_type( self, value ):
		self._thisptr.bc_type = self._bc_types[value]

	@property
	def nx(self):
		return self._thisptr.nx

	@property
	def dx(self):
		return self._thisptr.dx

	@property
	def box(self):
		return self._thisptr.box

	@property
	def solver_type(self):
		return "Yee"

	@property
	def Ex( self ):
		cdef float *buf = <float *> self._thisptr.E_buf
		cdef int size = self._thisptr.gc[0] + self._thisptr.nx + self._thisptr.gc[1]
		tmp = np.asarray( <float [:size, :3]> buf )
		return tmp[ self._thisptr.gc[0] : self._thisptr.gc[0] + self._thisptr.nx, 0 ]

	@property
	def Ey( self ):
		cdef float *buf = <float *> self._thisptr.E_buf
		cdef int size = self._thisptr.gc[0] + self._thisptr.nx + self._thisptr.gc[1]
		tmp = np.asarray( <float [:size, :3]> buf )
		return tmp[ self._thisptr.gc[0] : self._thisptr.gc[0] + self._thisptr.nx, 1 ]

	@property
	def Ez( self ):
		cdef float *buf = <float *> self._thisptr.E_buf
		cdef int size = self._thisptr.gc[0] + self._thisptr.nx + self._thisptr.gc[1]
		tmp = np.asarray( <float [:size, :3]> buf )
		return tmp[ self._thisptr.gc[0] : self._thisptr.gc[0] + self._thisptr.nx, 2 ]

	@property
	def Bx( self ):
		cdef float *buf = <float *> self._thisptr.B_buf
		cdef int size = self._thisptr.gc[0] + self._thisptr.nx + self._thisptr.gc[1]
		tmp = np.asarray( <float [:size, :3]> buf )
		return tmp[ self._thisptr.gc[0] : self._thisptr.gc[0] + self._thisptr.nx, 0 ]

	@property
	def By( self ):
		cdef float *buf = <float *> self._thisptr.B_buf
		cdef int size = self._thisptr.gc[0] + self._thisptr.nx + self._thisptr.gc[1]
		tmp = np.asarray( <float [:size, :3]> buf )
		return tmp[ self._thisptr.gc[0] : self._thisptr.gc[0] + self._thisptr.nx, 1 ]

	@property
	def Bz( self ):
		cdef float *buf = <float *> self._thisptr.B_buf
		cdef int size = self._thisptr.gc[0] + self._thisptr.nx + self._thisptr.gc[1]
		tmp = np.asarray( <float [:size, :3]> buf )
		return tmp[ self._thisptr.gc[0] : self._thisptr.gc[0] + self._thisptr.nx, 2 ]


	@property
	def E_part( self ):
		cdef float *buf = <float *> self._thisptr.ext_fld.E_part_buf
		cdef int size = self._thisptr.gc[0] + self._thisptr.nx + self._thisptr.gc[1]
		tmp = np.asarray( <float [:size, :3]> buf )
		return tmp[  : , : ]

	@property
	def B_part( self ):
		cdef float *buf = <float *> self._thisptr.ext_fld.B_part_buf
		cdef int size = self._thisptr.gc[0] + self._thisptr.nx + self._thisptr.gc[1]
		tmp = np.asarray( <float [:size, :3]> buf )
		return tmp[ :,: ]

	@property
	def E_buf( self ):
		cdef float *buf = <float *> self._thisptr.E_buf
		cdef int size = self._thisptr.gc[0] + self._thisptr.nx + self._thisptr.gc[1]
		tmp = np.asarray( <float [:size, :3]> buf )
		return tmp[  : ,: ]

	@property
	def B_buf( self ):
		cdef float *buf = <float *> self._thisptr.B_buf
		cdef int size = self._thisptr.gc[0] + self._thisptr.nx + self._thisptr.gc[1]
		tmp = np.asarray( <float [:size, :3]> buf )
		return tmp[ :,: ]


class Ext_Field:
	def __init__(self,sim,ext_B=None,ext_E=None):
		self.dx=sim.dx
		self.dt=sim.dt
		self.n_move=0
		self.ext_E=ext_E
		self.ext_B=ext_B
		self.if_move=True if (sim.if_move==1) else False
		# set the grid offsets
		ldx=sim.dx
		odx_b=np.empty([1,3])
		odx_b[0,0] = 0.0*ldx
		odx_b[0,1] = 0.5*ldx
		odx_b[0,2] = 0.5*ldx
		odx_e=np.empty([1,3])
		odx_e[0,0] = 0.5*ldx
		odx_e[0,1] = 0.0*ldx
		odx_e[0,2] = 0.0*ldx
		sim.emf.prep_ext_fld()
		self.odx_b=odx_b
		self.odx_e=odx_e
		self.ext_Efld=np.empty([3,len(sim.emf.E_part[:,0])])
		self.ext_Bfld=np.empty([3,len(sim.emf.B_part[:,0])])
		self.calc_ext(sim,0,len(sim.emf.E_part[:,0]))

	def move_win_ext(self,sim):
		if(sim.iter*self.dt>self.dx*self.n_move+1):
			for i in range(len(sim.emf.Ex_part)-2):
				self.ext_Efld[:,i]=self.ext_Efld[:,i+1]
				self.ext_Bfld[:,i]=self.ext_Bfld[:,i+1]

			self.calc_ext(sim,len(sim.emf.Ex_part)-2,len(sim.emf.E_part[:,0]))
			self.n_move=self.n_move+1

	def calc_ext(self,sim,lb,ub):
		for i in range(lb,ub):
			if(self.ext_B):
				x_eval = (i-1)*sim.dx + np.array(self.odx_b[0,:])
				#x dim
				B_eval = self.ext_B(x_eval[0])[0]
				self.ext_Bfld[0,i]=B_eval
				#y dim
				B_eval = self.ext_B(x_eval[1])[1]
				self.ext_Bfld[1,i]=B_eval
				#z dim
				B_eval = self.ext_B(x_eval[2])[2]
				self.ext_Bfld[2,i]=B_eval
			if(self.ext_E):
				x_eval = (i-1)*sim.dx + np.array(self.odx_e[0, :])
				#x dim
				E_eval = self.ext_E(x_eval[0])[0]
				self.ext_Efld[0,i]=E_eval
				#y dim
				E_eval = self.ext_E(x_eval[1])[1]
				self.ext_Efld[1,i]=E_eval
				#z dim
				E_eval = self.ext_E(x_eval[2])[2]
				self.ext_Efld[2,i]=E_eval

	def update_ext(self,sim):
		if self.if_move:
			self.move_win_ext(sim)
		sim.emf.prep_ext_fld()
		for i in range(len(sim.emf.E_part[:,0])):
			sim.emf.B_part[i,0]=sim.emf.B_buf[i,0]+self.ext_Bfld[0,i]
			sim.emf.B_part[i,1]=sim.emf.B_buf[i,1]+self.ext_Bfld[1,i]
			sim.emf.B_part[i,2]=sim.emf.B_buf[i,2]+self.ext_Bfld[2,i]

			sim.emf.E_part[i,0]=sim.emf.E_buf[i,0]+self.ext_Efld[0,i]
			sim.emf.E_part[i,1]=sim.emf.E_buf[i,1]+self.ext_Efld[1,i]
			sim.emf.E_part[i,2]=sim.emf.E_buf[i,2]+self.ext_Efld[2,i]


cdef class Laser:
	"""Extension type to wrap t_emf_laser objects"""

	cdef t_emf_laser * _thisptr

	def __cinit__( self, *, float start = 0.0, float fwhm = 0.0,
		           float rise = 0.0, float flat = 0.0, float fall = 0.0,
	               float a0 = 0.0, float omega0 = 0.0, float polarization = 0.0 ):
		self._thisptr = <t_emf_laser *> calloc(1, sizeof(t_emf_laser))

		self._thisptr.start = start
		self._thisptr.fwhm = fwhm
		self._thisptr.rise = rise
		self._thisptr.flat = flat
		self._thisptr.fall = fall
		self._thisptr.a0 = a0
		self._thisptr.omega0 = omega0
		self._thisptr.polarization = polarization

	def __dealloc__(self):
		free( self._thisptr )

	@property
	def start(self):
		return self._thisptr.start

	@start.setter
	def start(self,value):
		self._thisptr.start = value

	@property
	def fwhm(self):
		return self._thisptr.fwhm

	@fwhm.setter
	def fwhm(self,value):
		self._thisptr.fwhm = value

	@property
	def rise(self):
		return self._thisptr.rise

	@rise.setter
	def rise(self,value):
		self._thisptr.rise = value

	@property
	def flat(self):
		return self._thisptr.flat

	@flat.setter
	def flat(self,value):
		self._thisptr.flat = value

	@property
	def fall(self):
		return self._thisptr.fall

	@fall.setter
	def fall(self,value):
		self._thisptr.fall = value

	@property
	def a0(self):
		return self._thisptr.a0

	@a0.setter
	def a0(self,value):
		self._thisptr.a0 = value

	@property
	def omega0(self):
		return self._thisptr.omega0

	@omega0.setter
	def omega0(self,value):
		self._thisptr.omega0 = value

	@property
	def polarization(self):
		return self._thisptr.polarization

	@polarization.setter
	def polarization(self,value):
		self._thisptr.polarization = value


class Antenna:
	def __init__( self, *, start = 0.0,  fwhm = 0.0,rise = 0.0,\
                 flat = 0.0, fall = 0.0, a0 = 0.0, omega0 = 0.0,\
                 phase0=0.0,polarization = 0.0,propagation="forward" ):
		self.launch_time = start
		self.rise = rise
		self.flat = flat
		self.fall = fall
		self.a0 = a0
		self.omega0 = omega0
		self.polarization = polarization
		self.propagation = propagation
		self.phase0=phase0
		if fwhm != 0:
			if fwhm <= 0:
				print( "Invalid laser FWHM, must be > 0, aborting.\n" )
				raise
			self.rise = fwhm
			self.fall = fwhm
			self.flat=0.0
			self.fwhm=fwhm
		if self.rise<=0:
			print("Invalid laser RISE, must be > 0, aborting.\n")
			raise
		if self.fall<=0:
			print("Invalid laser FALL, must be > 0, aborting.\n")
			raise
		if self.flat<0:
			print("Invalid laser FLAT, must be > 0, aborting.\n")
			raise

	def time_env(self,t):
		length = self.rise + self.flat + self.fall
		if  t < 0.0:
			return 0
		elif  t < self.rise:
			return np.sin( np.pi/2* t/self.rise )**2
		elif  t < self.rise + self.flat:
			return 1
		elif  t < length:
			return np.sin( np.pi/2*(length-t)/self.fall ) ** 2
		else:
			return 0

	def launch(self,sim):
		if (self.propagation == "forward"):
			inpos = 0
			prop_sign = +1.0
		elif(self.propagation == "backward"):
			inpos = -1
			prop_sign = -1.0
		else:
			print("Invalid propagation direction")
			raise
		dtdx=sim.dt/sim.dx
		inj_time = sim.t - self.launch_time
		cos_pol = + np.cos( self.polarization ) * prop_sign
		sin_pol = - np.sin( self.polarization ) * prop_sign
		amp = 2.0* self.omega0 * self.a0 * self.time_env(inj_time ) * \
			dtdx * np.cos( self.omega0*inj_time + self.phase0)

		#print(amp*sin_pol,sim.emf.By[inpos])
		sim.emf.By[inpos]=sim.emf.By[inpos]+amp*sin_pol
		sim.emf.Bz[inpos]=sim.emf.Bz[inpos]+amp*cos_pol
		#print(amp*sin_pol,sim.emf.By[inpos],sim.emf.By[inpos-1],sim.emf.By[inpos+1])
cdef class Current:
	"""Extension type to wrap t_current objects"""

	cdef t_current* _thisptr

	cdef associate( self, t_current* ptr ):
		self._thisptr = ptr

	def zero(self):
		current_zero(self._thisptr)

	def update(self):
		current_update(self._thisptr)


	def report( self, char jc ):
		current_report( self._thisptr, jc )
	@property
	def Jx( self ):
		cdef float *buf = <float *> self._thisptr.J_buf
		cdef int size = self._thisptr.gc[0] + self._thisptr.nx + self._thisptr.gc[1]
		tmp = np.asarray( <float [:size, :3]> buf )
		return tmp[ self._thisptr.gc[0] : self._thisptr.gc[0] + self._thisptr.nx, 0 ]

	@property
	def Jy( self ):
		cdef float *buf = <float *> self._thisptr.J_buf
		cdef int size = self._thisptr.gc[0] + self._thisptr.nx + self._thisptr.gc[1]
		tmp = np.asarray( <float [:size, :3]> buf )
		return tmp[ self._thisptr.gc[0] : self._thisptr.gc[0] + self._thisptr.nx, 0 ]

	@property
	def Jz( self ):
		cdef float *buf = <float *> self._thisptr.J_buf
		cdef int size = self._thisptr.gc[0] + self._thisptr.nx + self._thisptr.gc[1]
		tmp = np.asarray( <float [:size, :3]> buf )
		return tmp[ self._thisptr.gc[0] : self._thisptr.gc[0] + self._thisptr.nx, 0 ]


cdef class Smooth:
	"""Extension type to wrap t_smooth objects"""

	cdef t_smooth* _thisptr

    # Filter types
	_filter_types = {'none'        : NONE,
                     'binomial'    : BINOMIAL,
                     'compensated' : COMPENSATED}

	def __cinit__( self, *, str xtype = 'none', int xlevel = 0 ):
		self._thisptr = <t_smooth *> calloc(1, sizeof(t_smooth))

		self._thisptr.xtype = self._filter_types[xtype]
		self._thisptr.xlevel = xlevel

	def __dealloc__(self):
		free( self._thisptr )

	@property
	def xtype(self):
		return self._thisptr.xtype

	@xtype.setter
	def xtype( self, value ):
		self._thisptr.xtype = value

	@property
	def xlevel(self):
		return self._thisptr.xlevel

	@xlevel.setter
	def xlevel( self, value ):
		self._thisptr.xlevel = value


cdef class Simulation:
	"""Extension type to wrap t_simulation objects"""

	cdef t_simulation *_thisptr
	cdef int n
	cdef float t

	cdef EMF emf
	cdef Current current
	cdef list species

	cdef object report

	def __cinit__( self, int nx, float box, float dt, *, species = None,
	               report = None, seed=None ):

		# Sanity checks
		if ( nx < 2 ):
			print("Invalid number of cells", file = sys.stderr)
			return

		if ( box <= 0 ):
			print("Invalid box size, must be > 0", file = sys.stderr)
			return

		if ( dt < 0 ):
			print("Invalid time-step, must be > 0", file = sys.stderr)
			return

		if ( dt >= box/nx ):
			print("Invalid timestep (courant condition violation), dt must be < {:g}".format( box/nx ) , file = sys.stderr)
			return

		# Allocate the simulation object
		self._thisptr = <t_simulation *> calloc(1, sizeof(t_simulation))

		# Initialize the random number generator
		# These are the value set when launching a new C simulation
		if(seed):
			set_rand_seed( int(seed), int(seed*4) )
		else:
			set_rand_seed( 12345, 67890 )

		# Initialize particle species data
		self.species = []
		cdef Species s

		cdef int n_species
		cdef t_species* species_

		if ( isinstance( species, Species )):
			n_species = 1
			species_ = <t_species *> calloc( 1, sizeof(t_species))
			s = species
			s.new( &species_[0], nx, box, dt )
			self.species.append( s )

		elif ( isinstance( species, (list,tuple) ) ):
			n_species = len( species )
			species_ = <t_species *> calloc( n_species, sizeof(t_species))
			for i in range(n_species):
				s = species[i]
				s.new( &species_[i], nx, box, dt )
				self.species.append( s )
		else:
			n_species = 0
			species_ = NULL

		# Diagnostics
		self.report = report

		# Initialize simulation
		sim_new( self._thisptr, nx, box, dt, 0.0, 0, species_, n_species )

		self.n = 0
		self.t = 0.0

		self.emf = EMF()
		self.emf.associate( &self._thisptr.emf )

		self.current = Current()
		self.current.associate( &self._thisptr.current )

	def __dealloc__(self):
		sim_delete( self._thisptr )
		free(self._thisptr)

	def set_moving_window(self):
		sim_set_moving_window( self._thisptr )

	def set_smooth(self, Smooth smooth):
		sim_set_smooth( self._thisptr, smooth._thisptr )

	def add_laser(self, Laser laser):
		sim_add_laser( self._thisptr, laser._thisptr )

	def get_species(self):
		return self.species

	def advance(self):
		self.n = self.n+1
		self.t = self.n * self._thisptr.dt

	def iter( self ):
		self.current.zero()
		for spec in self.species:
			spec.advance(self)
		self.current.update()
		self.emf.advance(self)

		#sim_iter( self._thisptr )
		self.n = self.n+1
		self.t = self.n * self._thisptr.dt

	def run( self, float tmax ):

		if ( tmax < self.t ):
			print("Simulation is already at t = {:g}".format(self.t))
			return

		print("\nRunning simulation up to t = {:g} ...".format(tmax))

		if ( self.report ):

			# Run simulation with diagnostics
			while self.t <= tmax:
				print('n = {:d}, t = {:g}'.format(self.n,self.t), end = '\r')
				self.report( self )
				sim_iter( self._thisptr )
				self.n = self.n+1
				self.t = self.n * self._thisptr.dt
		else:
			# Run simulation without diagnostics
			while self.t <= tmax:
				print('n = {:d}, t = {:g}'.format(self.n,self.t), end = '\r')
				sim_iter( self._thisptr )
				self.n = self.n+1
				self.t = self.n * self._thisptr.dt

		print('n = {:d}, t = {:g}'.format(self.n,self.t), end = '\r')
		print("\nDone.")

	@property
	def emf(self):
		return self.emf

	@property
	def current(self):
		return self.current

	@property
	def n(self):
		return self.n

	@property
	def t(self):
		return self.t

	@property
	def if_move(self):
		return self._thisptr.moving_window

	@property
	def dt(self):
		return self._thisptr.dt

	@property
	def dx(self):
		return self.emf.dx

	@property
	def nx(self):
		return self.emf.nx

	@property
	def box(self):
		return self.emf.box

	@property
	def report(self):
		return self.report

	@report.setter
	def report( self, f ):
		self.report = f
