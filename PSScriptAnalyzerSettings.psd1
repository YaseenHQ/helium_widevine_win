@{
    ExcludeRules = @(
        # The script is a single-file installer, not a module, so its verbs are
        # not exported and the unapproved-verb check does not apply.
        'PSUseApprovedVerbs',

        # Write-Host is deliberate for progress text that must not pollute the
        # object output the script returns on the pipeline.
        'PSAvoidUsingWriteHost'
    )
}
