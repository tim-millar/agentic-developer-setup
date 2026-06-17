# Framework Adapters

Framework adapters specialise the baseline for particular application frameworks.

They capture framework-specific development and operational patterns such as:

- common local commands
- test and console conventions
- framework-specific documentation notes
- common CI and hook implications

Framework adapters should not define project-specific architecture or domain rules.

Path:

```text
adapters/frameworks/<name>
```

Framework adapters are usually combined with:
- one ecosystem adapter
- one runtime adapter
- optionally one app-shape adapter
