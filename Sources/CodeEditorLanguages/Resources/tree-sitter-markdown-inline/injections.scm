; Injections for tree-sitter-markdown_inline (not the block markdown grammar).
((html_tag) @injection.content
  (#set! injection.language "html"))

((latex_block) @injection.content
  (#set! injection.language "latex"))
