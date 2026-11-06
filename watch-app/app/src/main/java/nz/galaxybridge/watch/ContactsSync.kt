package nz.galaxybridge.watch

import android.content.ContentProviderOperation
import android.content.Context
import android.provider.ContactsContract
import android.provider.ContactsContract.CommonDataKinds.Email
import android.provider.ContactsContract.CommonDataKinds.Phone
import android.provider.ContactsContract.CommonDataKinds.StructuredName
import android.provider.ContactsContract.RawContacts
import android.util.Log
import org.json.JSONObject

/**
 * Copies iPhone contacts into the watch's own contacts, so the watch's Phone app can call them
 * by name. They go into the watch's local "Phone" account, tagged with a source id starting
 * "gb:" so a resync replaces only what this app put there.
 *
 * Arrives in pages: {"page": 0, "pages": n, "items": [{"id", "n", "p": [..], "e": [..]}]}.
 * Page 0 clears our previous copy first.
 */
object ContactsSync {
    private const val TAG = "ContactsSync"
    private const val ACCOUNT = "vnd.sec.contact.phone"
    private const val PREFIX = "gb:"
    private val PHONE = Regex("^[0-9+*#() .\\-]{2,32}$")

    fun receive(s: LinkService, j: JSONObject) {
        val page = j.optInt("page", -1)
        val pages = j.optInt("pages", -1)
        val items = j.optJSONArray("items") ?: return
        if (page < 0 || pages !in 1..200 || page >= pages || items.length() > 200) return
        if (s.checkSelfPermission(android.Manifest.permission.WRITE_CONTACTS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            Features.result(s, "contacts", false, "Allow Contacts for Galaxy Bridge on the watch")
            return
        }
        if (page == 0) clear(s)
        val ops = ArrayList<ContentProviderOperation>()
        for (i in 0 until items.length()) {
            val o = items.optJSONObject(i) ?: continue
            val id = o.optString("id").take(80).filter { it.isLetterOrDigit() || it in ":-_/" }
            val name = Features.clean(o.optString("n")).trim().take(80)
            val phones = o.optJSONArray("p")?.let { a -> (0 until minOf(a.length(), 8)).map { a.optString(it) } }
                ?.filter { PHONE.matches(it) }.orEmpty()
            val emails = o.optJSONArray("e")?.let { a -> (0 until minOf(a.length(), 4)).map { a.optString(it).take(120) } }
                ?.filter { '@' in it && it.none(Char::isWhitespace) }.orEmpty()
            if (id.isEmpty() || name.isEmpty() || (phones.isEmpty() && emails.isEmpty())) continue
            val back = ops.size
            ops += ContentProviderOperation.newInsert(RawContacts.CONTENT_URI)
                .withValue(RawContacts.ACCOUNT_TYPE, ACCOUNT).withValue(RawContacts.ACCOUNT_NAME, ACCOUNT)
                .withValue(RawContacts.SOURCE_ID, PREFIX + id).build()
            ops += data(back).withValue(ContactsContract.Data.MIMETYPE, StructuredName.CONTENT_ITEM_TYPE)
                .withValue(StructuredName.DISPLAY_NAME, name).build()
            for (p in phones) ops += data(back).withValue(ContactsContract.Data.MIMETYPE, Phone.CONTENT_ITEM_TYPE)
                .withValue(Phone.NUMBER, p).withValue(Phone.TYPE, Phone.TYPE_MOBILE).build()
            for (e in emails) ops += data(back).withValue(ContactsContract.Data.MIMETYPE, Email.CONTENT_ITEM_TYPE)
                .withValue(Email.ADDRESS, e).withValue(Email.TYPE, Email.TYPE_HOME).build()
            // Keep each transaction well under the provider's limit.
            if (ops.size > 300) { apply(s, ops); ops.clear() }
        }
        apply(s, ops)
        if (page == pages - 1) Features.result(s, "contacts", true, "${count(s)} contacts on the watch")
    }

    private fun data(back: Int) = ContentProviderOperation.newInsert(ContactsContract.Data.CONTENT_URI)
        .withValueBackReference(ContactsContract.Data.RAW_CONTACT_ID, back)

    private fun apply(c: Context, ops: ArrayList<ContentProviderOperation>) {
        if (ops.isEmpty()) return
        runCatching { c.contentResolver.applyBatch(ContactsContract.AUTHORITY, ops) }
            .onFailure { Log.w(TAG, "batch failed", it) }
    }

    private fun clear(c: Context) {
        val uri = RawContacts.CONTENT_URI.buildUpon()
            .appendQueryParameter(ContactsContract.CALLER_IS_SYNCADAPTER, "true").build()
        c.contentResolver.delete(uri, "${RawContacts.SOURCE_ID} LIKE ? AND ${RawContacts.ACCOUNT_TYPE} = ?", arrayOf("$PREFIX%", ACCOUNT))
    }

    private fun count(c: Context): Int = c.contentResolver.query(RawContacts.CONTENT_URI, arrayOf(RawContacts._ID),
        "${RawContacts.SOURCE_ID} LIKE ? AND ${RawContacts.DELETED} = 0", arrayOf("$PREFIX%"), null)?.use { it.count } ?: 0
}
