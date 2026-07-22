(module
  (memory 1)
  (func (export "run") (result i32)
    (drop (memory.grow (i32.const 1000)))
    (memory.grow (i32.const 1000))))
