package tunnelbahn.app.ui

/**
 * Splits free-form CIDR input (newline/space separated) into (valid, invalid) tokens
 * for inline validation feedback. Pure Kotlin (no Android APIs) so it is unit-testable.
 */
fun parseCidrLines(text: String): Pair<List<String>, List<String>> {
    val valid = mutableListOf<String>()
    val invalid = mutableListOf<String>()
    for (token in text.split('\n', ' ', '\t', ',')) {
        val t = token.trim()
        if (t.isEmpty()) continue
        if (isValidCidr(t)) valid.add(t) else invalid.add(t)
    }
    return valid to invalid
}

private fun isValidCidr(s: String): Boolean {
    val slash = s.indexOf('/')
    if (slash <= 0 || slash == s.length - 1) return false
    val addr = s.substring(0, slash)
    val prefix = s.substring(slash + 1).toIntOrNull() ?: return false
    return when {
        addr.contains(':') -> prefix in 0..128 && isValidIpv6(addr)
        else -> prefix in 0..32 && isValidIpv4(addr)
    }
}

private fun isValidIpv4(addr: String): Boolean {
    val parts = addr.split('.')
    if (parts.size != 4) return false
    return parts.all { p ->
        val n = p.toIntOrNull() ?: return false
        p == n.toString() && n in 0..255
    }
}

private fun isValidIpv6(addr: String): Boolean {
    // Light validation: hex groups separated by ':', at most one "::" compression.
    if (addr.count { it == ':' } < 1) return false
    val doubleColon = addr.split("::")
    if (doubleColon.size > 2) return false
    val groups = addr.split(':').filter { it.isNotEmpty() }
    return groups.all { g -> g.length in 1..4 && g.all { it.isDigit() || it.lowercaseChar() in 'a'..'f' } }
}
