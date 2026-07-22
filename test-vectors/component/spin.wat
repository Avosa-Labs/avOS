(module
  (func (export "run") (result i32)
    (loop $spin (br $spin))
    i32.const 0))
