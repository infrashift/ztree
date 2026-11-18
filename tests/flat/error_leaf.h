/* C++ in a C header: the C grammar gives an ERROR leaf for the backslash.
   The leaf has no error cost, but ts_node_has_error is true for it. */
struct Num<B, '\'', D>
