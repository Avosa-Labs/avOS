(module
  (func $recurse (result i32) (call $recurse))
  (func (export "run") (result i32) (call $recurse)))
