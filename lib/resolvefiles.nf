/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    INPUT & STAGE FILE RESOLUTION FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include {
    formatValidationError
    extractSampleId
} from './utils'

def buildConditionMeta(condition_id, sheet_ctx, source_label = 'replicated peak file') {
    if (!sheet_ctx.condition_to_target.containsKey(condition_id)) {
        error "Condition '${condition_id}' (from ${source_label}) not found in samplesheet (${sheet_ctx.path}). Available conditions: ${sheet_ctx.conditions.sort().join(', ')}"
    }
    def target_name = sheet_ctx.condition_to_target[condition_id]
    return [
        id       : condition_id,
        condition: condition_id,
        target   : target_name,
        peak_mode: sheet_ctx.target_to_peak_mode[target_name]
    ]
}

def buildTargetMeta(target_name, sheet_ctx, source_label = 'target file') {
    if (!(target_name in sheet_ctx.targets)) {
        error "Target '${target_name}' (from ${source_label}) not found in samplesheet (${sheet_ctx.path}). Available targets: ${sheet_ctx.targets.sort().join(', ')}"
    }
    return [
        id       : target_name,
        target   : target_name,
        peak_mode: sheet_ctx.target_to_peak_mode[target_name]
    ]
}

def resolveInputFiles(pattern, sheet_or_map, suffixes = [], Map opts = [:]) {
    def samples_map   = sheet_or_map.containsKey('samples') ? sheet_or_map.samples : sheet_or_map
    def sheet_path    = sheet_or_map.containsKey('path') ? sheet_or_map.path : 'samplesheet.csv'
    def path_type     = opts.type ?: 'file'
    def skip_empty    = opts.skipEmpty ?: false
    def file_label             = opts.label ?: 'input file'
    def expected_ids           = opts.expectedIds ?: []
    def require_bai            = opts.requireBai ?: false
    def error_on_unrecognized  = opts.errorOnUnrecognized ?: false

    def matched_files = files(pattern, type: path_type, checkIfExists: false)
    def valid_entries = []
    def found_ids     = [] as Set
    def ignored_files = []
    def errors        = []

    matched_files.each { f ->
        def sample_id = extractSampleId(f, suffixes)
        if (!samples_map.containsKey(sample_id)) {
            if (error_on_unrecognized) {
                errors.add("Unrecognized ${file_label} '${f}' (extracted sample_id '${sample_id}' is not in samplesheet.csv). Remove this file to proceed, or add '${sample_id}' to samplesheet.csv (valid sample_ids: ${samples_map.keySet().sort().join(', ')}).")
            } else {
                ignored_files.add("${f.name} (sample_id '${sample_id}')")
            }
            return
        }
        if (skip_empty && f.size() == 0) {
            log.warn "Skipping 0-byte ${file_label} (Dropbox online-only placeholder?): ${f}"
            return
        }
        def meta = samples_map[sample_id]
        found_ids.add(sample_id)

        if (require_bai) {
            def bai_file = file("${f}.bai", checkIfExists: false)
            if (!bai_file.exists()) {
                errors.add("Missing BAM index (.bai) for sample_id '${sample_id}': expected '${f}.bai'.")
                return
            }
            valid_entries.add([ meta, f, bai_file ])
        } else {
            valid_entries.add([ meta, f ])
        }
    }

    if (ignored_files) {
        log.info "Ignoring ${ignored_files.size()} ${file_label}(s) not listed in samplesheet.csv: ${ignored_files.sort().join(', ')}"
    }

    expected_ids.each { req_id ->
        if (!(req_id in found_ids)) {
            errors.add("Missing required ${file_label} for sample_id '${req_id}' (listed in samplesheet.csv) matching pattern: ${pattern}")
        }
    }

    if (errors) {
        error(formatValidationError("INPUT FILE VALIDATION FAILED (${file_label})", sheet_path, errors))
    }

    return channel.fromList(valid_entries)
}

def resolveConditionFiles(pattern, sheet_ctx, suffixes = [], Map opts = [:]) {
    def file_label          = opts.label ?: 'replicated peak file'
    def expected_conditions = opts.expectedConditions ?: []
    def matched_files       = files(pattern, checkIfExists: false)
    def valid_entries       = []
    def found_conditions    = [] as Set
    def ignored_files       = []
    def errors              = []

    matched_files.each { f ->
        def condition_id = extractSampleId(f, suffixes)
        if (!sheet_ctx.condition_to_target.containsKey(condition_id)) {
            ignored_files.add("${f.name} (condition '${condition_id}')")
            return
        }
        found_conditions.add(condition_id)
        valid_entries.add([ buildConditionMeta(condition_id, sheet_ctx, file_label), f ])
    }

    if (ignored_files) {
        log.info "Ignoring ${ignored_files.size()} ${file_label}(s) not listed in samplesheet.csv: ${ignored_files.sort().join(', ')}"
    }

    expected_conditions.each { req_cond ->
        if (!(req_cond in found_conditions)) {
            errors.add("Missing required ${file_label} for condition '${req_cond}' (listed in samplesheet.csv) matching pattern: ${pattern}")
        }
    }

    if (errors) {
        error(formatValidationError("CONDITION FILE VALIDATION FAILED (${file_label})", sheet_ctx.path, errors))
    }

    return channel.fromList(valid_entries)
}

def resolveTargetFiles(pattern, sheet_ctx, suffixes = [], Map opts = [:]) {
    def file_label       = opts.label ?: 'target peak file'
    def expected_targets = opts.expectedTargets ?: []
    def matched_files    = files(pattern, checkIfExists: false)
    def valid_entries    = []
    def found_targets    = [] as Set
    def ignored_files    = []
    def errors           = []

    matched_files.each { f ->
        def target_name = extractSampleId(f, suffixes)
        if (!(target_name in sheet_ctx.targets)) {
            ignored_files.add("${f.name} (target '${target_name}')")
            return
        }
        found_targets.add(target_name)
        valid_entries.add([ buildTargetMeta(target_name, sheet_ctx, file_label), f ])
    }

    if (ignored_files) {
        log.info "Ignoring ${ignored_files.size()} ${file_label}(s) not listed in samplesheet.csv: ${ignored_files.sort().join(', ')}"
    }

    expected_targets.each { req_target ->
        if (!(req_target in found_targets)) {
            errors.add("Missing required ${file_label} for target '${req_target}' (listed in samplesheet.csv) matching pattern: ${pattern}")
        }
    }

    if (errors) {
        error(formatValidationError("TARGET FILE VALIDATION FAILED (${file_label})", sheet_ctx.path, errors))
    }

    return channel.fromList(valid_entries)
}

def resolveContrastFiles(pattern, contrast_map, sheet_ctx, suffixes = [], Map opts = [:]) {
    def file_label         = opts.label ?: 'differential peak file'
    def expected_contrasts = opts.expectedContrasts ?: []
    def matched_files      = files(pattern, checkIfExists: false)
    def valid_entries      = []
    def found_contrasts    = [] as Set
    def ignored_files      = []
    def errors             = []

    matched_files.each { f ->
        def contrast_id = extractSampleId(f, suffixes)
        if (!contrast_map.containsKey(contrast_id)) {
            ignored_files.add("${f.name} (contrast '${contrast_id}')")
            return
        }
        found_contrasts.add(contrast_id)
        valid_entries.add([ contrast_map[contrast_id], f ])
    }

    if (ignored_files) {
        log.info "Ignoring ${ignored_files.size()} ${file_label}(s) not configured in params.diff_contrasts: ${ignored_files.sort().join(', ')}"
    }

    expected_contrasts.each { req_id ->
        if (!(req_id in found_contrasts)) {
            errors.add("Missing required ${file_label} for contrast '${req_id}' (defined in params.diff_contrasts) matching pattern: ${pattern}")
        }
    }

    if (errors) {
        error(formatValidationError("CONTRAST FILE VALIDATION FAILED (${file_label})", sheet_ctx.path, errors))
    }

    return channel.fromList(valid_entries)
}
