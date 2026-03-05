@{
    # These rules produce noisy false-positives in this repo due to common patterns:
    # - Nested helper functions inside other functions
    # - Pester BeforeEach/It scoping patterns
    #
    # We still keep script analysis enabled; we only suppress these two rules.
    ExcludeRules = @(
        'PSUseApprovedVerbs',
        'PSUseDeclaredVarsMoreThanAssignments'
    )
}
