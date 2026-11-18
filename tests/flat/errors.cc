// ERROR nodes: an ERROR node has no fields, and an ERROR leaf has an error
// with no error cost.
template<unsigned B, char D, char... Ds>
  struct Num<B, '\'', D, Ds...>
  : Num<B, D, Ds...>
  { };
int f(int x {
  return x;
