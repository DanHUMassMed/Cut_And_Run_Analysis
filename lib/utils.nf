/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    SHARED PIPELINE UTILITY FUNCTIONS
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
