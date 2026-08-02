; Highlights for the pinned tree-sitter-verilog grammar (LANG-N06).
; Validated against the package pin; nvim-treesitter queries are not pin-aligned.
(comment) @comment

(simple_identifier) @variable

(module_declaration) @type

(system_tf_identifier) @function

(unsigned_number) @number

(string_literal) @string

[
  "begin"
  "end"
  "module"
  "endmodule"
] @keyword
