/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    UTILITY FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/


def loadSamplesheetMap(samplesheet_path) {
    def meta_map = [:]
    if (!samplesheet_path) {
        return meta_map
    }
    def sheet_file = file(samplesheet_path)
    if (!sheet_file.exists()) {
        return meta_map
    }
    sheet_file.splitCsv(header: true, strip: true).each { row ->
        if (row.sample_id) {
            meta_map[row.sample_id] = [
                id         : row.sample_id,
                single_end : false,
                sample_name: row.sample_name ?: row.sample_id,
                condition  : row.condition ?: (row.sample_name ?: 'default'),
                target     : row.target ?: 'default',
                replicate  : row.replicate ? row.replicate.toInteger() : 1,
                control_id : row.control_id ?: null
            ]
        }
    }
    return meta_map
}
/*
 * Extracts the sample ID by removing a matching suffix, 
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


def buildMeta(sample_id, samplesheet_map) {
    if (!samplesheet_map.containsKey(sample_id)) {
        error "Sample ID '${sample_id}' not found in samplesheet. Available IDs: ${samplesheet_map.keySet().sort().join(', ')}"
    }

    return samplesheet_map[sample_id]
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

def resolvePairedFastq(pattern, samplesheet_map, suffixes = []) {
    channel
        .fromFilePairs(pattern)
        .map { pair_id, reads ->
            def sample_id = suffixes ? extractSampleId(pair_id, suffixes) : pair_id
            [ buildMeta(sample_id, samplesheet_map), reads ]
        }
}

def resolveInputFiles(pattern, samplesheet_map, suffixes = [], Map opts = [:]) {
    def path_type = opts.type ?: 'file'
    def check_exists = opts.containsKey('checkIfExists') ? opts.checkIfExists : false
    def skip_empty = opts.skipEmpty ?: false
    def file_label = opts.label ?: 'file'

    def ch = channel.fromPath(pattern, type: path_type, checkIfExists: check_exists)

    if (skip_empty) {
        ch = ch.filter { f ->
            if (f.size() == 0) {
                log.warn "Skipping 0-byte ${file_label} (Dropbox online-only placeholder?): ${f}"
                return false
            }
            return true
        }
    }

    return ch.map { f ->
        def sample_id = extractSampleId(f, suffixes)
        [ buildMeta(sample_id, samplesheet_map), f ]
    }
}