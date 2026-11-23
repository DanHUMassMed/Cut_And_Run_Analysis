/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    SAMPLESHEET & CONTRAST VALIDATION FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include {
    isControlTarget
    formatValidationError
} from './utils'

def parseSamplesheetRows(samplesheet_path) {
    def required_columns = [
        'sample_id',
        'sample_name',
        'condition',
        'target',
        'peak_mode',
        'replicate',
        'control_id'
    ]

    if (!samplesheet_path || samplesheet_path.toString().trim().isEmpty()) {
        error(formatValidationError(
            'SAMPLESHEET VALIDATION FAILED',
            '(unset)',
            ["params.samplesheet is not set. Provide a valid path to samplesheet.csv."]
        ))
    }

    def sheet_file = file(samplesheet_path)
    if (!sheet_file.exists()) {
        error(formatValidationError(
            'SAMPLESHEET VALIDATION FAILED',
            samplesheet_path,
            ["Samplesheet file does not exist at path: ${sheet_file}"]
        ))
    }

    def raw_lines = sheet_file.readLines('UTF-8')
    if (!raw_lines || raw_lines.every { it.trim().isEmpty() }) {
        error(formatValidationError(
            'SAMPLESHEET VALIDATION FAILED',
            sheet_file,
            ["Samplesheet file is empty."]
        ))
    }

    def header_line_idx = raw_lines.findIndexOf { !it.trim().isEmpty() }
    def header_raw = raw_lines[header_line_idx].replace('\uFEFF', '')
    def header_cols = header_raw.split(',', -1).collect { it.trim() }

    def missing_cols = required_columns.findAll { col -> !(col in header_cols) }
    if (missing_cols) {
        error(formatValidationError(
            'SAMPLESHEET VALIDATION FAILED',
            sheet_file,
            [
                "Missing required column header(s): ${missing_cols.join(', ')}.",
                "Expected headers: ${required_columns.join(', ')}",
                "Found headers   : ${header_cols.join(', ')}"
            ]
        ))
    }

    def non_empty_line_numbers = []
    raw_lines.eachWithIndex { line, idx ->
        if (idx > header_line_idx && !line.trim().isEmpty()) {
            non_empty_line_numbers.add(idx + 1)
        }
    }

    def csv_rows = sheet_file.splitCsv(header: true, strip: true)
    def normalized_rows = []
    csv_rows.eachWithIndex { raw_row, idx ->
        def clean_row = [:]
        raw_row.each { k, v ->
            def clean_key = k.toString().replace('\uFEFF', '').trim()
            clean_row[clean_key] = v != null ? v.toString().trim() : ''
        }
        def line_num = idx < non_empty_line_numbers.size() ? non_empty_line_numbers[idx] : (idx + 2)
        if (clean_row.values().any { !it.isEmpty() }) {
            clean_row._line = line_num
            normalized_rows.add(clean_row)
        }
    }

    if (normalized_rows.isEmpty()) {
        error(formatValidationError(
            'SAMPLESHEET VALIDATION FAILED',
            sheet_file,
            ["Samplesheet contains a header row but no sample data rows."]
        ))
    }

    return [
        file: sheet_file,
        rows: normalized_rows
    ]
}

def validateSamplesheetRows(parsed) {
    def sheet_file = parsed.file
    def rows       = parsed.rows
    def safe_id_re = /^[A-Za-z0-9][A-Za-z0-9._-]*$/
    def errors     = []

    def samples                 = [:]
    def seen_sample_ids         = [:]
    def seen_cond_replicate     = [:]
    def seen_target_sample_name = [:]
    def condition_to_target_loc = [:]
    def target_to_peak_mode_loc = [:]

    rows.each { row ->
        def line_num      = row._line
        def sample_id     = row.sample_id   ?: ''
        def sample_name   = row.sample_name ?: ''
        def condition     = row.condition   ?: ''
        def target        = row.target      ?: ''
        def peak_mode_raw = row.peak_mode   ?: ''
        def peak_mode     = peak_mode_raw.toLowerCase()
        def rep_str       = row.replicate   ?: ''
        def control_id    = row.control_id  ?: ''
        def is_igg        = isControlTarget(target)

        def row_missing = []
        if (!sample_id)                 { row_missing.add('sample_id') }
        if (!sample_name)               { row_missing.add('sample_name') }
        if (!condition)                 { row_missing.add('condition') }
        if (!target)                    { row_missing.add('target') }
        if (!is_igg && !peak_mode_raw)  { row_missing.add('peak_mode') }
        if (!rep_str)                   { row_missing.add('replicate') }

        if (row_missing) {
            errors.add("[Line ${line_num}] Missing required value(s) for column(s): ${row_missing.join(', ')}${sample_id ? " (sample_id '${sample_id}')" : ''}.")
        }

        if (sample_id && !(sample_id ==~ safe_id_re)) {
            errors.add("[Line ${line_num}] Invalid sample_id '${sample_id}'. Must start with an alphanumeric character and contain only letters, digits, '.', '_', or '-'.")
        }
        if (sample_name && (sample_name =~ /\s/)) {
            errors.add("[Line ${line_num}] Invalid sample_name '${sample_name}' for sample_id '${sample_id ?: '(missing)'}'. sample_name must not contain spaces or whitespace.")
        }
        if (condition && !(condition ==~ safe_id_re)) {
            errors.add("[Line ${line_num}] Invalid condition '${condition}' for sample_id '${sample_id ?: '(missing)'}'. Must start with an alphanumeric character and contain only letters, digits, '.', '_', or '-'.")
        }
        if (condition && condition.equalsIgnoreCase('default')) {
            errors.add("[Line ${line_num}] Invalid condition '${condition}' for sample_id '${sample_id ?: '(missing)'}'. 'default' is reserved; specify an explicit biological condition name.")
        }
        if (target && !(target ==~ safe_id_re)) {
            errors.add("[Line ${line_num}] Invalid target '${target}' for sample_id '${sample_id ?: '(missing)'}'. Must start with an alphanumeric character and contain only letters, digits, '.', '_', or '-'.")
        }
        if (target && target.equalsIgnoreCase('default')) {
            errors.add("[Line ${line_num}] Invalid target '${target}' for sample_id '${sample_id ?: '(missing)'}'. 'default' is reserved; specify an explicit target mark (e.g., H3K4me3, H3K27me3, IgG).")
        }
        if (!is_igg && peak_mode_raw && !(peak_mode in ['narrow', 'broad'])) {
            errors.add("[Line ${line_num}] Invalid peak_mode '${peak_mode_raw}' for sample_id '${sample_id ?: '(missing)'}'. Must be 'narrow' or 'broad' for experimental targets.")
        }
        if (is_igg && peak_mode_raw && !(peak_mode in ['narrow', 'broad', 'control'])) {
            errors.add("[Line ${line_num}] Invalid peak_mode '${peak_mode_raw}' for IgG control sample_id '${sample_id ?: '(missing)'}'. Leave peak_mode empty for IgG rows.")
        }

        def replicate = null
        if (rep_str) {
            if (!rep_str.isInteger()) {
                errors.add("[Line ${line_num}] Invalid replicate '${rep_str}' for sample_id '${sample_id ?: '(missing)'}'. 'replicate' must be a positive integer (1, 2, ...).")
            } else {
                replicate = rep_str.toInteger()
                if (replicate < 1) {
                    errors.add("[Line ${line_num}] Invalid replicate '${rep_str}' for sample_id '${sample_id ?: '(missing)'}'. 'replicate' must be >= 1.")
                }
            }
        }

        if (sample_id) {
            if (seen_sample_ids.containsKey(sample_id)) {
                errors.add("[Line ${line_num}] Duplicate sample_id '${sample_id}' (first seen on Line ${seen_sample_ids[sample_id]}).")
            } else {
                seen_sample_ids[sample_id] = line_num
            }
        }

        if (row_missing) {
            return
        }

        if (replicate != null) {
            def cond_rep_key = "${condition}::${replicate}"
            if (seen_cond_replicate.containsKey(cond_rep_key)) {
                errors.add("[Line ${line_num}] Duplicate replicate ${replicate} for condition '${condition}' (first seen on Line ${seen_cond_replicate[cond_rep_key]}).")
            } else {
                seen_cond_replicate[cond_rep_key] = line_num
            }
        }

        def target_name_key = "${target}::${sample_name}"
        if (seen_target_sample_name.containsKey(target_name_key)) {
            errors.add("[Line ${line_num}] Duplicate sample_name '${sample_name}' within target '${target}' (first seen on Line ${seen_target_sample_name[target_name_key]}).")
        } else {
            seen_target_sample_name[target_name_key] = line_num
        }

        if (condition_to_target_loc.containsKey(condition)) {
            def prev = condition_to_target_loc[condition]
            if (prev.target != target) {
                errors.add("[Line ${line_num}] Condition '${condition}' is assigned to multiple targets ('${prev.target}' on Line ${prev.line}, '${target}' on Line ${line_num}). Each condition must belong to a single target (e.g., '${condition}_${prev.target}', '${condition}_${target}').")
            }
        } else {
            condition_to_target_loc[condition] = [ target: target, line: line_num ]
        }

        if (!is_igg && target && (peak_mode in ['narrow', 'broad'])) {
            if (target_to_peak_mode_loc.containsKey(target)) {
                def prev_pm = target_to_peak_mode_loc[target]
                if (prev_pm.peak_mode != peak_mode) {
                    errors.add("[Line ${line_num}] Target '${target}' is assigned conflicting peak_mode values ('${prev_pm.peak_mode}' on Line ${prev_pm.line}, '${peak_mode}' on Line ${line_num}). All samples for target '${target}' must use the same peak_mode.")
                }
            } else {
                target_to_peak_mode_loc[target] = [ peak_mode: peak_mode, line: line_num ]
            }
        }

        samples[sample_id] = [
            id         : sample_id,
            single_end : false,
            sample_name: sample_name,
            condition  : condition,
            target     : target,
            peak_mode  : is_igg ? null : peak_mode,
            replicate  : replicate ?: 1,
            control_id : control_id ?: null,
            _line      : line_num
        ]
    }

    // Cross-row validation for control_id and experimental targets
    def non_igg_samples = samples.values().findAll { meta -> !isControlTarget(meta) }
    if (samples && non_igg_samples.isEmpty()) {
        errors.add("Samplesheet contains only IgG control rows. At least one non-IgG experimental target row is required.")
    }

    samples.values().each { meta ->
        def ctrl_id = meta.control_id
        if (!ctrl_id) {
            return
        }
        if (isControlTarget(meta)) {
            errors.add("[Line ${meta._line}] IgG control sample '${meta.id}' must not specify a control_id ('${ctrl_id}'). Leave control_id empty for IgG rows.")
            return
        }
        if (ctrl_id == meta.id) {
            errors.add("[Line ${meta._line}] sample_id '${meta.id}' cannot reference itself as control_id.")
            return
        }
        if (!samples.containsKey(ctrl_id)) {
            errors.add("[Line ${meta._line}] Unknown control_id '${ctrl_id}' for sample_id '${meta.id}'. '${ctrl_id}' was not found in the sample_id column of samplesheet.csv.")
            return
        }
        def ctrl_meta = samples[ctrl_id]
        if (!isControlTarget(ctrl_meta)) {
            errors.add("[Line ${meta._line}] Invalid control_id '${ctrl_id}' for sample_id '${meta.id}': sample '${ctrl_id}' has target '${ctrl_meta.target}', but control_id must reference an 'IgG' sample.")
        }
    }

    if (errors) {
        error(formatValidationError('SAMPLESHEET VALIDATION FAILED', sheet_file, errors))
    }

    // Strip internal _line helper key from emitted sample metadata maps
    def clean_samples = [:]
    samples.each { sid, meta ->
        clean_samples[sid] = meta.findAll { k, _v -> k != '_line' }
    }

    def condition_to_target = [:]
    condition_to_target_loc.each { cond, info ->
        condition_to_target[cond] = info.target
    }

    def target_to_peak_mode = [:]
    target_to_peak_mode_loc.each { tgt, info ->
        target_to_peak_mode[tgt] = info.peak_mode
    }

    def non_igg_sample_ids = clean_samples.values()
        .findAll { !isControlTarget(it) }
        .collect { it.id } as Set

    def control_sample_ids = clean_samples.values()
        .findAll { isControlTarget(it) }
        .collect { it.id } as Set

    def all_sample_ids = clean_samples.keySet() as Set

    def referenced_control_ids = clean_samples.values()
        .findAll { !isControlTarget(it) && it.control_id }
        .collect { it.control_id } as Set

    def samples_without_control = clean_samples.values()
        .findAll { !isControlTarget(it) && !it.control_id }
        .collect { it.id } as Set

    def non_igg_targets = clean_samples.values()
        .findAll { !isControlTarget(it) }
        .collect { it.target } as Set

    def non_igg_conditions = clean_samples.values()
        .findAll { !isControlTarget(it) }
        .collect { it.condition } as Set

    return [
        path                   : sheet_file.toString(),
        samples                : clean_samples,
        condition_to_target    : condition_to_target,
        target_to_peak_mode    : target_to_peak_mode,
        non_igg_sample_ids     : non_igg_sample_ids,
        control_sample_ids     : control_sample_ids,
        all_sample_ids         : all_sample_ids,
        referenced_control_ids : referenced_control_ids,
        samples_without_control: samples_without_control,
        targets                : non_igg_targets,
        all_targets            : clean_samples.values().collect { it.target } as Set,
        conditions             : non_igg_conditions,
        all_conditions         : clean_samples.values().collect { it.condition } as Set
    ]
}

def loadAndValidateSamplesheet(samplesheet_path) {
    def parsed = parseSamplesheetRows(samplesheet_path)
    return validateSamplesheetRows(parsed)
}

def validateDiffContrasts(diff_contrasts, sheet_ctx, config_path = null) {
    if (!diff_contrasts) {
        return [:]
    }

    def source_path   = config_path ?: "${launchDir}/config/experiment.config"
    def safe_id_re    = /^[A-Za-z0-9][A-Za-z0-9._-]*$/
    def errors        = []
    def seen_ids      = [:]
    def contrast_map  = [:]
    def valid_targets = sheet_ctx.targets.sort().join(', ')
    def valid_conds   = sheet_ctx.all_conditions.sort().join(', ')

    diff_contrasts.eachWithIndex { c, idx ->
        def entry_num  = idx + 1
        def cid        = (c?.id         ?: '').toString().trim()
        def treatment  = (c?.treatment  ?: '').toString().trim()
        def background = (c?.background ?: '').toString().trim()
        def target     = (c?.target     ?: '').toString().trim()

        def missing = []
        if (!cid)        { missing.add('id') }
        if (!treatment)  { missing.add('treatment') }
        if (!background) { missing.add('background') }
        if (!target)     { missing.add('target') }

        if (missing) {
            errors.add("[Contrast #${entry_num}] Missing required field(s): ${missing.join(', ')}.")
            return
        }

        if (!(cid ==~ safe_id_re)) {
            errors.add("[Contrast '${cid}'] Invalid id '${cid}'. Must start with an alphanumeric character and contain only letters, digits, '.', '_', or '-'.")
        }
        if (seen_ids.containsKey(cid)) {
            errors.add("[Contrast '${cid}'] Duplicate contrast id '${cid}' (first defined at Contrast #${seen_ids[cid]}).")
        } else {
            seen_ids[cid] = entry_num
        }

        if (treatment == background) {
            errors.add("[Contrast '${cid}'] treatment ('${treatment}') and background ('${background}') must be different conditions.")
        }

        if (!(target in sheet_ctx.targets)) {
            errors.add("[Contrast '${cid}'] Unknown target '${target}'. Not found among experimental targets in samplesheet.csv (valid targets: ${valid_targets}).")
        }

        if (!(treatment in sheet_ctx.all_conditions)) {
            errors.add("[Contrast '${cid}'] Unknown treatment condition '${treatment}'. Not found in samplesheet.csv (valid conditions: ${valid_conds}).")
        } else if (target && sheet_ctx.condition_to_target[treatment] != target) {
            errors.add("[Contrast '${cid}'] Treatment condition '${treatment}' has target '${sheet_ctx.condition_to_target[treatment]}' in samplesheet.csv, which does not match contrast target '${target}'.")
        }

        if (!(background in sheet_ctx.all_conditions)) {
            errors.add("[Contrast '${cid}'] Unknown background condition '${background}'. Not found in samplesheet.csv (valid conditions: ${valid_conds}).")
        } else if (target) {
            def bg_target = sheet_ctx.condition_to_target[background]
            if (bg_target != target && !isControlTarget(bg_target)) {
                errors.add("[Contrast '${cid}'] Background condition '${background}' has target '${bg_target}' in samplesheet.csv, which does not match contrast target '${target}' (or 'IgG').")
            }
        }

        contrast_map[cid] = [
            id        : cid,
            treatment : treatment,
            background: background,
            target    : target
        ]
    }

    if (errors) {
        error(formatValidationError(
            'DIFFERENTIAL CONTRASTS VALIDATION FAILED (params.diff_contrasts)',
            source_path,
            errors
        ))
    }

    return contrast_map
}
