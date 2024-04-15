<script context="module" lang="ts">

// localStorage keys
export const LS_REMOTE_RANDOM_DATAROOT_KEY='syncRemoteDataPrefix'
export const LS_SHORT_ENCRYPTION_CODE_KEY = 'syncTransferrableEncryptionCode'
export const LS_ENCRYPTION_KEY_KEY = 'syncEncryptionKey'
export const LS_DEBUG_MODE_KEY = 'syncDebugMode'
export const LS_LAST_SYNC_TIME_KEY = 'syncLastTime'
export const LS_DELETED_CHAT_SYNC_IDS_KEY = 'syncDeletedChatSyncIds'

// remoteStorage path fragments
export const RS_CHATS_FOLDER = "chat"
export const RS_DELETED_CHATS_FOLDER = "delchat"
export const RS_MODTIMES_FOLDER = "modtime"
export const RS_GLOBAL_MODTIME_KEY = "globalmodtime"
export const RS_RANDOM_DATAROOT_KEY = "maindataroot"

export const TIMESTAMP_DATATYPE = {type:'object', properties: {ts:'number'}}
// object key names are for compatibility with CryptoJS.CipherParams
export const ENCPACKAGE_DATATYPE = {type:'object', properties: {iv:'string', ciphertext:'string'}}

export const SECRET_CODE_LENGTH_BYTES = 9
export const SECRET_CODE_LENGTH_CHARS = Math.ceil(SECRET_CODE_LENGTH_BYTES * 4 / 3)
// SALT is a fixed random string, representing 16 bytes, that just makes our key generation function
// different from everyone else's, to defeat rainbow attackes. It should not be changed.
// Generated from: CryptoJS.enc.Base64.stringify(CryptoJS.lib.WordArray.random(128 / 8)) // 16 bytes
export const SALT="c1nz5E76XhE1syNEdDZUbg=="

// these are not private. their origin and redirect URIs are controlled, so it's safe to expose them.
// ask dustin before trying to get Google Drive backend working. It was very annoying.
export const DROPBOX_APP_KEY = "b9d3shwwpioyfdq"
// export const GOOGLE_OAUTH_CLIENT_ID = "381600737192-4lsoivpus2boavlhgp8otgncl3ne36t5.apps.googleusercontent.com"


</script>