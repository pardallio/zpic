# Non-MPI options
# CC = gcc
# CFLAGS = -Ofast -std=c99 -pedantic

# MPI options
CC = mpicc
CFLAGS = -D_MPI_ -Ofast -std=c99 -pedantic


SOURCE = current.c emf.c particles.c random.c timer.c main.c simulation.c zdf.c

TARGET = zpic

OBJ = $(SOURCE:.c=.o)

all : $(SOURCE) $(TARGET)

$(TARGET) : $(OBJ)
	$(CC) $(CFLAGS) $(LDFLAGS) $(OBJ) -o $@

.c.o:
	$(CC) -c $(CFLAGS) $< -o $@

clean:
	@touch $(TARGET) $(OBJ)
	rm -f $(TARGET) $(OBJ)
