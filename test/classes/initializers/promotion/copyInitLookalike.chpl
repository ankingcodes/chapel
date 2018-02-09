
class C {
  type eltType;
  var x : eltType;

  proc chpl__promotionType() type {
    return eltType;
  }

  iter these() {
    for i in 1..10 do yield i*x;
  }

  proc init(x : int) {
    this.eltType = int;
    this.x = x;
    super.init();
  }

  proc init(r : real) {
    this.eltType = real;
    this.x = r;
    super.init();
  }

  proc init(other:C(int)) {
    writeln("copy init for 'int'");
    this.eltType = other.eltType;
    this.x = other.x;
    super.init();
  }
}

proc main() {
  var ci = new C(1);
  var cr = new C(2.0);

  // No copy initializer for C(real), so this program should fail to compile
  // (at least by the current rules). This test was written to make sure we
  // do not allow promotion for calls that look like copy initializers. For
  // example, without some compiler work this new-statement could promote to
  // init(r : real), which would be very confusing.
  var q = new C(cr);
  writeln("q = ", q);

  delete q, cr, ci;
}
