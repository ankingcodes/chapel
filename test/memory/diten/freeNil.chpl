def main {
  use MemAlloc, Memory;
  var m1, m2: uint(64);
  var o: opaque;
  m1 = memoryUsed();
  chpl_free(o, true, -1, "");
  m2 = memoryUsed();
  writeln((m1, m2));
}

