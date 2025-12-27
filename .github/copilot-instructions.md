# Well Architecture Reliability Assessment script Instructions

## Project Context
This project is an assessment script to collect and analyze  azure resources. It's used to generate reports and network topology diagrams on the reliability of a given azure environment. It includes four main components: Collector(Start-WARACollector), Analyzer(Start-WARAAnalyzer), Reporter(Start-WARAReport), and Network Topology Generator(Export-WARANetworkTopology). Collector and Analyzer can run in the target azure environment. The results are saved to json and xlsx files which is the input of Reporter and Network Topology Generator. Reporter and Network Topology Generator run locally without requiring access to the target azure environment. 
- **Type**: Powershell 7+ Module and Cmdlets
- **Testing Framework**: Pester

## Development Guidelines

### 1. Avoid Over-Engineering
- **Simplicity First**: Implement the simplest solution that meets the requirements. Do not anticipate future needs that haven't been stated.
- **Error Handling**:
  - If an error condition is encountered, throw an error or return a failure status immediately.
  - **DO NOT** implement complex fallback logic unless explicitly requested.
  - Fail fast and loudly to aid debugging.

### 2. Test-Driven Development (TDD)
- **Mandatory Testing**: For every new function, component, or logic block, you **MUST** write unit tests.
- **Test Coverage**:
  - **Happy Path**: Verify standard usage works as expected.
  - **Corner Cases**: Test boundary conditions, null/undefined inputs, empty strings, and edge cases.
  - **Error States**: Verify that errors are thrown/handled correctly as per the "Avoid Over-Engineering" rule.
- **Location**: All unit tests must be placed in a `test/` directory at the project root.
- **Execution**: You must run the tests and ensure they pass before marking a task as complete.
  - *Note*: If the testing framework (e.g., Jest) is not configured, you must set it up first.

### 3. Documentation
- **Requirement**: All implemented code must be documented.
- **Content**: Describe the architecture, component hierarchy, and public interfaces/APIs.
- **Location**: Documentation must be placed in a `docs/` directory at the project root.
- **Maintenance**:
  - Prioritize updating existing documentation files (e.g., `docs/architecture.md`) over creating new files.
  - Create new files only if the feature is a distinct module.

### 4. Code Style & Formatting
- **NO EMOJIS**: Do not use emojis anywhere.
- **Conventions**: Follow standard PowerShell best practices.

## Workflow Checklist
Before finishing a response/task:
1. [ ] Is the code simple and direct? (No over-engineering)
2. [ ] Are there unit tests in `src/tests/`?
3. [ ] Do the tests pass?
4. [ ] Is the architecture documented in `docs/`?