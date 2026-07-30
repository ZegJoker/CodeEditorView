# FullWorkbench example

**Profile:** Workspace + Workbench + language services + search/tasks/SCM/terminal products linked.

```bash
swift build
swift run
```

Opens a temporary folder as a workspace inside `WorkbenchView`. Tooling products are constructed to prove linkage; production hosts should register commands and panels explicitly (see `Docs/Guides/PRODUCT-SELECTION.md` and PHASE notes).
