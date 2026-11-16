/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    UTILITY & VALIDATION FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

def isControlTarget(meta_or_target) {
    def target_val = meta_or_target instanceof Map
        ? meta_or_target.target
        : meta_or_target
    return target_val != null && target_val.toString().trim().equalsIgnoreCase('igg')
}

def formatValidationError(title, source_path, errors) {
    def divider = '=' * 72
    def sub_div = '-' * 72
    def bullet_lines = errors.collect { err -> "  - ${err}" }.join('\n')
    return "\n${divider}\n ${title}\n File: ${source_path}\n${sub_div}\n${bullet_lines}\n${divider}\n"
}

def parseSamplesheetRows(samplesheet_path) {
    def required_columns = [
        'sample_id',
        'sample_name',
        'condition',
        'target',
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

    rows.each { row ->
        def line_num    = row._line
        def sample_id   = row.sample_id   ?: ''
        def sample_name = row.sample_name ?: ''
        def condition   = row.condition   ?: ''
        def target      = row.target      ?: ''
        def rep_str     = row.replicate   ?: ''
        def control_id  = row.control_id  ?: ''

        def row_missing = []
        if (!sample_id)   { row_missing.add('sample_id') }
        if (!sample_name) { row_missing.add('sample_name') }
        if (!condition)   { row_missing.add('condition') }
        if (!target)      { row_missing.add('target') }
        if (!rep_str)     { row_missing.add('replicate') }

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

        samples[sample_id] = [
            id         : sample_id,
            single_end : false,
            sample_name: sample_name,
            condition  : condition,
            target     : target,
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

    def non_igg_sample_ids = clean_samples.values()
        .findAll { !isControlTarget(it) }
        .collect { it.id } as Set

    def non_igg_targets = clean_samples.values()
        .findAll { !isControlTarget(it) }
        .collect { it.target } as Set

    def non_igg_conditions = clean_samples.values()
        .findAll { !isControlTarget(it) }
        .collect { it.condition } as Set

    return [
        path               : sheet_file.toString(),
        samples            : clean_samples,
        condition_to_target: condition_to_target,
        non_igg_sample_ids : non_igg_sample_ids,
        targets            : non_igg_targets,
        all_targets        : clean_samples.values().collect { it.target } as Set,
        conditions         : non_igg_conditions,
        all_conditions     : clean_samples.values().collect { it.condition } as Set
    ]
}

def loadAndValidateSamplesheet(samplesheet_path) {
    def parsed = parseSamplesheetRows(samplesheet_path)
    return validateSamplesheetRows(parsed)
}

def loadSamplesheetMap(samplesheet_path) {
    return loadAndValidateSamplesheet(samplesheet_path).samples
}

def validateDiffContrasts(diff_contrasts, sheet_ctx) {
    if (!diff_contrasts) {
        return [:]
    }

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
            sheet_ctx.path,
            errors
        ))
    }

    return contrast_map
}

/*
 * Extracts the entity ID by removing a matching suffix,
 * falling back to the filename without its extension.
 */
def extractSampleId(input, suffixes = []) {
    def name = input instanceof Path
        ? input.getName()
        : input.toString()

    def matched_suffix = suffixes.find { suffix -> name.endsWith(suffix) }

    if (matched_suffix) {
        return name.substring(0, name.length() - matched_suffix.length())
    }

    return input instanceof Path
        ? input.getBaseName()
        : name
}

def buildMeta(sample_id, sheet_or_map, source_label = 'file') {
    def samples_map = sheet_or_map.containsKey('samples') ? sheet_or_map.samples : sheet_or_map
    if (!samples_map.containsKey(sample_id)) {
        error "Sample ID '${sample_id}' (from ${source_label}) not found in samplesheet. Available sample_ids: ${samples_map.keySet().sort().join(', ')}"
    }
    return samples_map[sample_id]
}

def buildConditionMeta(condition_id, sheet_ctx, source_label = 'replicated peak file') {
    if (!sheet_ctx.condition_to_target.containsKey(condition_id)) {
        error "Condition '${condition_id}' (from ${source_label}) not found in samplesheet (${sheet_ctx.path}). Available conditions: ${sheet_ctx.conditions.sort().join(', ')}"
    }
    def target_name = sheet_ctx.condition_to_target[condition_id]
    return [
        id       : condition_id,
        condition: condition_id,
        target   : target_name
    ]
}

def buildTargetMeta(target_name, sheet_ctx, source_label = 'target file') {
    if (!(target_name in sheet_ctx.targets)) {
        error "Target '${target_name}' (from ${source_label}) not found in samplesheet (${sheet_ctx.path}). Available targets: ${sheet_ctx.targets.sort().join(', ')}"
    }
    return [
        id    : target_name,
        target: target_name
    ]
}

def resolveBowtie2Index(index_param) {
    def bt2_files = files("${index_param}*.bt2*")

    if (!bt2_files) {
        error "No Bowtie2 index files found for prefix: ${index_param}"
    }

    return [
        [ id: file(index_param).name ],
        bt2_files
    ]
}

def resolveChromSizes(chrom_sizes_param) {
    if (!chrom_sizes_param) {
        return []
    }
    def cs_file = file(chrom_sizes_param)
    return cs_file.exists() ? cs_file : []
}

def resolvePairedFastq(pattern, sheet_or_map, suffixes = []) {
    channel
        .fromFilePairs(pattern)
        .map { pair_id, reads ->
            def sample_id = suffixes ? extractSampleId(pair_id, suffixes) : pair_id
            [ buildMeta(sample_id, sheet_or_map, 'FASTQ pair'), reads ]
        }
}

def resolveInputFiles(pattern, sheet_or_map, suffixes = [], Map opts = [:]) {
    def samples_map   = sheet_or_map.containsKey('samples') ? sheet_or_map.samples : sheet_or_map
    def sheet_path    = sheet_or_map.containsKey('path') ? sheet_or_map.path : 'samplesheet.csv'
    def path_type     = opts.type ?: 'file'
    def skip_empty    = opts.skipEmpty ?: false
    def file_label    = opts.label ?: 'input file'
    def expected_ids  = opts.expectedIds ?: []
    def require_bai   = opts.requireBai ?: false

    def matched_files = files(pattern, type: path_type, checkIfExists: false)
    def valid_entries = []
    def found_ids     = [] as Set
    def errors        = []

    matched_files.each { f ->
        if (skip_empty && f.size() == 0) {
            log.warn "Skipping 0-byte ${file_label} (Dropbox online-only placeholder?): ${f}"
            return
        }
        def sample_id = extractSampleId(f, suffixes)
        if (!samples_map.containsKey(sample_id)) {
            errors.add("Unrecognized ${file_label} '${f.name}': extracted sample_id '${sample_id}' is not in samplesheet.csv (valid sample_ids: ${samples_map.keySet().sort().join(', ')}).")
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
    def errors              = []

    matched_files.each { f ->
        def condition_id = extractSampleId(f, suffixes)
        if (!sheet_ctx.condition_to_target.containsKey(condition_id)) {
            errors.add("Unrecognized ${file_label} '${f.name}': extracted condition '${condition_id}' is not in samplesheet.csv (valid conditions: ${sheet_ctx.conditions.sort().join(', ')}).")
            return
        }
        found_conditions.add(condition_id)
        valid_entries.add([ buildConditionMeta(condition_id, sheet_ctx, file_label), f ])
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
    def errors           = []

    matched_files.each { f ->
        def target_name = extractSampleId(f, suffixes)
        if (!(target_name in sheet_ctx.targets)) {
            errors.add("Unrecognized ${file_label} '${f.name}': extracted target '${target_name}' is not in samplesheet.csv (valid targets: ${sheet_ctx.targets.sort().join(', ')}).")
            return
        }
        found_targets.add(target_name)
        valid_entries.add([ buildTargetMeta(target_name, sheet_ctx, file_label), f ])
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
    def errors             = []

    matched_files.each { f ->
        def contrast_id = extractSampleId(f, suffixes)
        if (!contrast_map.containsKey(contrast_id)) {
            def valid_ids = contrast_map.keySet().sort().join(', ') ?: '(none configured in params.diff_contrasts)'
            errors.add("Unrecognized ${file_label} '${f.name}': extracted contrast_id '${contrast_id}' is not in params.diff_contrasts (valid contrast IDs: ${valid_ids}).")
            return
        }
        found_contrasts.add(contrast_id)
        valid_entries.add([ contrast_map[contrast_id], f ])
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
