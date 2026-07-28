; Markdown Inline — only node types present in tree-sitter-markdown-inline

(code_span) @text.literal
(latex_block) @text.literal

(emphasis) @text.emphasis
(link_text) @text.reference
(image_description) @text.reference

[
  (link_destination)
  (uri_autolink)
  (email_autolink)
] @text.uri

(link_title) @text.literal
(link_label) @text.reference

(backslash_escape) @string.escape
(entity_reference) @constant
(numeric_character_reference) @constant

(hard_line_break) @punctuation.special

[
  (shortcut_link)
  (full_reference_link)
  (collapsed_reference_link)
  (inline_link)
  (image)
] @text
