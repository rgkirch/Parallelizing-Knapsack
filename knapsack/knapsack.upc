#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/time.h>
#include <upc.h>

//
// auxiliary functions
//
inline int max( int a, int b ) { return a > b ? a : b; }
inline int min( int a, int b ) { return a < b ? a : b; }
double read_timer( )
{
    static int initialized = 0;
    static struct timeval start;
    struct timeval end;
    if( !initialized )
    {
        gettimeofday( &start, NULL );
        initialized = 1;
    }
    gettimeofday( &end, NULL );
    return (end.tv_sec - start.tv_sec) + 1.0e-6 * (end.tv_usec - start.tv_usec);
}


//
//  command line option processing
//
int find_option( int argc, char **argv, const char *option )
{
    int i;
    for(i = 1; i < argc; i++ )
        if( strcmp( argv[i], option ) == 0 )
            return i;
    return -1;
}

int read_int( int argc, char **argv, const char *option, int default_value )
{
    int iplace = find_option( argc, argv, option );
    if( iplace >= 0 && iplace < argc-1 )
        return atoi( argv[iplace+1] );
    return default_value;
}

char *read_string( int argc, char **argv, const char *option, char *default_value )
{
    int iplace = find_option( argc, argv, option );
    if( iplace >= 0 && iplace < argc-1 )
        return argv[iplace+1];
    return default_value;
}

//
//  solvers
//
int build_table( int nitems, int cap, shared int *T, shared int *w, shared int *v )
{
    int wj, vj;

    wj = w[0];
    vj = v[0];
	
	int i;
    upc_forall( i = 0;  i <  wj;  i++; &T[i] ) T[i] = 0;
    upc_forall( i = wj; i <= cap; i++; &T[i] ) T[i] = vj;
    upc_barrier;

	int j;
    for(j = 1; j < nitems; j++ )
    {
        wj = w[j];
        vj = v[j];
		int i;
        upc_forall( i = 0;  i <  wj;  i++; &T[i] ) T[i+cap+1] = T[i];
        upc_forall( i = wj; i <= cap; i++; &T[i] ) T[i+cap+1] = max( T[i], T[i-wj]+vj );
        upc_barrier;

        T += cap+1;
    }

    return T[cap];
}

void backtrack( int nitems, int cap, shared int *T, shared int *w, shared int *u )
{
    int i, j;

    if( MYTHREAD != 0 )
        return;

    i = nitems*(cap+1) - 1;
    for( j = nitems-1; j > 0; j-- )
    {
        u[j] = T[i] != T[i-cap-1];
        i -= cap+1 + (u[j] ? w[j] : 0 );
    }
    u[0] = T[i] != 0;
}

//
//  serial solver to check correctness
//
int solve_serial( int nitems, int cap, shared int *w, shared int *v )
{
    int i, j, best, *allocated, *T, wj, vj;

    //alloc local resources
    T = allocated = malloc( nitems*(cap+1)*sizeof(int) );
    if( !allocated )
    {
        fprintf( stderr, "Failed to allocate memory" );
        upc_global_exit( -1 );
    }

    //build_table locally
    wj = w[0];
    vj = v[0];
    for( i = 0;  i <  wj;  i++ ) T[i] = 0;
    for( i = wj; i <= cap; i++ ) T[i] = vj;
    for( j = 1; j < nitems; j++ )
    {
        wj = w[j];
        vj = v[j];
        for( i = 0;  i <  wj;  i++ ) T[i+cap+1] = T[i];
        for( i = wj; i <= cap; i++ ) T[i+cap+1] = max( T[i], T[i-wj]+vj );
        T += cap+1;
    }
    best = T[cap];

    //free resources
    free( allocated );

    return best;
}

//
//  benchmarking program
//
int main( int argc, char** argv )
{
    int i, best_value, best_value_serial, total_weight, nused, total_value;
    double seconds;
    shared int *weight;
    shared int *value;
    shared int *used;
    shared int *total;

	if( find_option( argc, argv, "-h" ) >= 0 )
    {
        printf( "Options:\n" );
        printf( "-h to see this help\n" );
        printf( "-c <int> to set the knapsack capacity\n" );
        printf( "-n <nitems> to specify the number of items\n" );
        printf( "-s <filename> to specify a summary file name\n" );
        return 0;
    }
	
    //these constants have little effect on runtime
    int max_value  = 1000;
    int max_weight = 1000;

    //reading in problem size
    int capacity   = read_int( argc, argv, "-c", 999 );
    int nitems     = read_int( argc, argv, "-n", 5000 );
	
	

    srand48( (unsigned int)time(NULL) + MYTHREAD );

    //allocate distributed arrays, use cyclic distribution
    weight = (shared int *) upc_all_alloc( nitems, sizeof(int) );
    value  = (shared int *) upc_all_alloc( nitems, sizeof(int) );
    used   = (shared int *) upc_all_alloc( nitems, sizeof(int) );
    total  = (shared int *) upc_all_alloc( nitems * (capacity+1), sizeof(int) );
    if( !weight || !value || !total || !used )
    {
        fprintf( stderr, "Failed to allocate memory" );
        upc_global_exit( -1 );
    }

    // init
    max_weight = min( max_weight, capacity );//don't generate items that don't fit into bag
    upc_forall( i = 0; i < nitems; i++; i )
    {
        weight[i] = 1 + (int)(lrand48()%max_weight);
        value[i]  = 1 + (int)(lrand48()%max_value);
    }

    upc_barrier;

    // time the solution
    seconds = read_timer( );

    best_value = build_table( nitems, capacity, total, weight, value );
    backtrack( nitems, capacity, total, weight, used );

    seconds = read_timer( ) - seconds;

    // check the result
    if( MYTHREAD == 0 )
    {
        printf( "%d items, capacity: %d, time: %g\n", nitems, capacity, seconds );

        best_value_serial = solve_serial( nitems, capacity, weight, value );

        total_weight = nused = total_value = 0;
        for( i = 0; i < nitems; i++ )
            if( used[i] )
            {
                nused++;
                total_weight += weight[i];
                total_value += value[i];
            }

        printf( "%d items used, value %d, weight %d\n", nused, total_value, total_weight );

        if( best_value != best_value_serial || best_value != total_value || total_weight > capacity )
            printf( "WRONG SOLUTION\n" );
		
		// Doing summary data
		char *sumname = read_string( argc, argv, "-s", NULL );
		FILE *fsum = sumname ? fopen ( sumname, "a" ) : NULL;
		if( fsum) 
			fprintf(fsum,"%d %d %d %g\n",nitems,capacity,THREADS,seconds);
		if( fsum )
			fclose( fsum );    
		

        //release resources
        upc_free( weight );
        upc_free( value );
        upc_free( total );
        upc_free( used );
    }

    return 0;
}
