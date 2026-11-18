/* An old-style definition: an inherited field names a grandchild. */
int add(a, b)
int a;
int b;
{
  return a + b;
}

/* A MISSING #endif: an empty sibling after the identifier. */
#ifdef EXTRA
int extra;
