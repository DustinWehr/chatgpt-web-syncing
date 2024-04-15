<script context="module" lang="ts">
import CryptoJS from 'crypto-js'
import { chatsStorage, getGlobalSettings } from '../Storage.svelte';
import { LS_REMOTE_RANDOM_DATAROOT_KEY, RS_RANDOM_DATAROOT_KEY, SALT, SECRET_CODE_LENGTH_BYTES, LS_SHORT_ENCRYPTION_CODE_KEY, LS_ENCRYPTION_KEY_KEY, LS_DEBUG_MODE_KEY, LS_LAST_SYNC_TIME_KEY, LS_DELETED_CHAT_SYNC_IDS_KEY } from './SyncConstants.svelte';
import { ChatsSyncer } from './ChatsSyncer.svelte'
import { get, writable} from 'svelte/store'
import { vlog, verror, vwarn, throttled, hashFn, showProgress } from './SyncUtil.svelte';
import type { Chat } from '../Types.svelte';

window.CryptoJS = CryptoJS

/**
   * As much as possible, this is the interface between chatgptweb's sync feature and the rest of the app.
   *
   * - Types: .syncId is added to the Chat datatype when the sync feature is enabled.
   *
   * - The Storage module calls maybeAutoSync() in most cases after saving chats to localStorage
   *
   * The remaining uses of SyncFeatureAPI are all in GUI modules:
   * 
   * - Home: There is a new sync settings section. It is hidden except for a checkbox when the feature is disabled.
   *
   * - Settings: I followed the lead of the Pedals UI by registering two new boolean settings in GlobalSetting.
   *   I wasn't consistent, however; there are a couple other bits of persistent state added to localStorage, including
   *   the short encryption secret and derived encryption key. The constants are named in SyncConstants.svelte.
   *
   * - Sidebar: I added a sync button with a familiar icon in the bottom-left (when feature enabled). When the sync feature is enabled, it is
   *   sensible for there to be a sync button reachable only by scrolling.
   *
   * The actual chats syncing method is in ChatsSyncer.svelte.
   **/

let chatsSyncer : ChatsSyncer|undefined = undefined

export let reactiveGeneratingShortSyncCode = writable(false)
export let reactiveJoiningShortSyncCode = writable(false)
export let reactiveHaveShortSyncCode = writable(haveShortEncryptionCode())
export let reactiveShowSyncSettings = writable(true)

export function encSetupToggle(firstDevice: boolean) {
  if (firstDevice) {
    reactiveGeneratingShortSyncCode.set(!get(reactiveGeneratingShortSyncCode))
    reactiveJoiningShortSyncCode.set(false)
  }
  else {
    reactiveJoiningShortSyncCode.set(!get(reactiveJoiningShortSyncCode))
    reactiveGeneratingShortSyncCode.set(false)
  }
}

export function syncSettingsToggle() {
  reactiveShowSyncSettings.set(!get(reactiveShowSyncSettings))
}

export function showFooterProgress(fraction: number|null, text: string) : void {
  return showProgress('footer-progress-display', fraction, text)  
}

// returns string of length SECRET_CODE_LENGTH_CHARS
export function newShortEncryptionCode() : string {
  while (true) {
    let rv =  CryptoJS.enc.Base64.stringify(CryptoJS.lib.WordArray.random(SECRET_CODE_LENGTH_BYTES))
    if (!rv.includes('I') && !rv.includes('l') && !rv.includes('1') && !rv.includes('O') && !rv.includes('0')) {
      return rv
    }
  }
}

export function getShortEncryptionCode() : string|null {
  return localStorage.getItem(LS_SHORT_ENCRYPTION_CODE_KEY)
}
export function haveShortEncryptionCode() : boolean {
  const v = localStorage.getItem(LS_SHORT_ENCRYPTION_CODE_KEY)
  return !!v && (v !== 'undefined') && (v !== 'null')
}

export function saveShortEncryptionCode(code:string) : void {
  localStorage.setItem(LS_SHORT_ENCRYPTION_CODE_KEY, code)
  reactiveHaveShortSyncCode.set(!!code)
  updateSyncFeatureSettingsView()
}

export function acceptNewShortEncryptionCode(code: string) {
  vlog(`acceptNewShortEncryptionCode(${code})`)
  saveShortEncryptionCode(code)
  withSyncFeature( (cs) => {
    clearRemoteSyncData('/', 
      async () => {
        const remaining = await checkRemoteSyncDataCleared()
        if (remaining > 0) {
          alert(`failed to clear all remote sync data!\n${remaining} values remaining.\nplease try again.`)
          return
        }
        cs.saveEncKeyFromNewCode(code)

        vwarn("clearRemoteSyncData should be done. Now setting random data root. Then syncing.")

        // we'll have at least this one value to test encryption key on other devices.
        useNewRandomPathPrefix(cs).then(() => {
          cs.syncChats()
        })
      },
      (x) => showFooterProgress(x, 'clearing encrypted chats on server')
    )
  })
}

// this is a hack for preventing an issue with remoteStorage from breaking sync
// see https://community.remotestorage.io/t/corrupt-empty-folders-on-remote-what-to-do/842
function useNewRandomPathPrefix(cs: ChatsSyncer) : Promise<any> {
  let prefix = "/" // just so while loop runs at least once
  while (prefix.indexOf('/') > -1) {
    prefix = CryptoJS.enc.Base64.stringify(CryptoJS.lib.WordArray.random(3))
  }
  vwarn('new random path prefix', prefix)
  return cs.rsclient.storeJsonObject(RS_RANDOM_DATAROOT_KEY, prefix, false).then(() => {
    localStorage.setItem(LS_REMOTE_RANDOM_DATAROOT_KEY, prefix)
    cs.rsclient.data_root = prefix
  })
}

export function shortEncryptCodeForJoinGroupEntered(code: string) {
  console.warn(`join code form value on submit: ${code}`)
  withSyncFeature( async (cs) => {
    saveShortEncryptionCode(code)
    
    const key8bytes = CryptoJS.PBKDF2(code, SALT, { keySize: 256 / 32 })
    const keyString = key8bytes.toString(CryptoJS.enc.Base64)
    localStorage.setItem(LS_ENCRYPTION_KEY_KEY, keyString)

    // RS_RANDOM_DATAROOT_KEY is just a key that definitely exists if remote storage was properly initialized.
    await cs.rsclient.getJsonObject(RS_RANDOM_DATAROOT_KEY, false)
      .catch((e) => {
        alert("Code failed to decrypt your data. Check it again.")
        console.error(e)
        // keep localStorage[SHORT_ENCRYPTION_CODE_STORAGE_KEY]; if user just made a typo, don't want it disappearing
        // from the input form
        delete localStorage[LS_ENCRYPTION_KEY_KEY]
      })
      .then((prefix) => {
        // if we get here, decryption was successful
        localStorage.setItem(LS_REMOTE_RANDOM_DATAROOT_KEY, prefix as string)
        cs.rsclient.data_root = prefix as string
        vlog("data root", prefix)
        alert("Validated code. Syncing now.")
        cs.syncChats()
      })
  })
}

function syncFeatureEnabled() : boolean {
  return getGlobalSettings().enableSyncFeature
}

export const maybeLoadSyncFeature = () => {
  vlog("maybeLoadSyncFeature")
  if (syncFeatureEnabled()) {
    if (!chatsSyncer) {
      chatsSyncer = new ChatsSyncer()
    }
  }
}

function ensureSyncReady() : ChatsSyncer {
  if (!chatsSyncer) {
    chatsSyncer = new ChatsSyncer()
  }
  return chatsSyncer
}

export function autosyncAfterLocalChangeActive() : boolean {
  return syncFeatureEnabled() && getGlobalSettings().autosyncAfterLocalChange
}

function withSyncFeature(f: (cs:ChatsSyncer) => void) : void {
  f(ensureSyncReady())
}

function whenAutosyncing(f: (cs:ChatsSyncer) => void) : void {
  if (autosyncAfterLocalChangeActive()) {
    withSyncFeature(f)
  }
}

export function whenSyncEnabled(f: (cs:ChatsSyncer) => void) : void {
  if (syncFeatureEnabled()) {
    withSyncFeature(f)
  }
}

// used at call sites that correspond to user actions that change chat data.
// see autosyncAfterLocalChange
export function maybeAutosync() : void {
  whenAutosyncing( (cs) => cs.syncChats() )
}

export function maybeSync() : void {
  whenSyncEnabled( (cs) => cs.syncChats() )
}


export function clearLocalSyncData() {
  let lchats = get(chatsStorage)
  for (let chat of lchats) {
    delete chat.syncId
  }
  chatsStorage.set(lchats)

  localStorage.removeItem(LS_SHORT_ENCRYPTION_CODE_KEY)
  reactiveHaveShortSyncCode.set(false)
  localStorage.removeItem(LS_REMOTE_RANDOM_DATAROOT_KEY)
  localStorage.removeItem(LS_ENCRYPTION_KEY_KEY)
  localStorage.removeItem(LS_DEBUG_MODE_KEY)
  localStorage.removeItem(LS_LAST_SYNC_TIME_KEY)
  localStorage.removeItem(LS_DELETED_CHAT_SYNC_IDS_KEY)
}

export function updateSyncFeatureSettingsView() {  
  whenSyncEnabled( (cs => addWidgetToSettingsPage(cs)) )  
}


function addWidgetToSettingsPage(cs: ChatsSyncer) {
  if (document.getElementById('remote-storage-widget-container')
  && !document.getElementById('remotestorage-widget')) {        
    document.getElementById('remote-storage-widget-container')!.innerHTML = ''
    const remoteStorageWidget = cs.newAuthWidget()
    remoteStorageWidget.attach('remote-storage-widget-container')
  }
}


async function getLeafPaths(start_path: string = '/') : Promise<string[]> {
  const rv : string[] = [];
  let prom : Promise<any>
  withSyncFeature( (cs) => {
    const helper = async (path: string) => {
      if (path.endsWith('/')) {
        await cs.rsclient.getListing(`${path}`, false).then(async (subdirlisting:any) => {
          for (const k of Object.keys(subdirlisting)) {
            await helper(`${path}${k}`)
          }
        }).catch(e => vwarn(`Error on getListing('${path}') in getLeafPaths(${start_path})`,e))
      }
      else rv.push(path)
    }
    prom = helper(start_path)
  })
  await prom!
  return rv
}

export async function checkRemoteSyncDataCleared(start_path: string = '/') : Promise<number> {
  vwarn('checkRemoteSyncDataCleared')
  const leafPathsToDelete = await getLeafPaths(start_path)
  return leafPathsToDelete.length
}

export async function clearRemoteSyncData(start_path: string = '/',
                          whendone?: () => void,
                          progressFeedback?: (fraction: number) => void) : Promise<void> {
  withSyncFeature( async (cs) => {
    const leafPathsToDelete = await getLeafPaths(start_path)
    vwarn(`${leafPathsToDelete.length} leaf paths to delete`)
    const deferreds : (() => Promise<any>)[] = []  
    for (const path of leafPathsToDelete) {
      deferreds.push(() => cs.rsclient.remove(`${path}`, false)
          .then(() => vlog(`remove of ${path} ok`))
          .catch(e => vwarn(`error on remove('${path}')`, e))
      )
    }
    throttled(deferreds, 200, whendone, progressFeedback)
  })  
}

export function dedupLocalChatsBySyncId() {
  const lchats = get(chatsStorage)
  const seen = new Set<string>()
  const rv : Chat[] = []
  for (const chat of lchats) {
    if (!chat.syncId) {
      vlog(`local chat without syncid found, name ${chat.name}`)
      rv.push(chat)
    }
    else if (!seen.has(chat.syncId)) {
      seen.add(chat.syncId)
      rv.push(chat)
    } else {
      vlog(`local chat dup (syncid) found, name ${chat.name}`)
    }
  }
  chatsStorage.set(rv)
}

export function dedupLocalChatsByHash(delete_remote=false) {
  const lchats = get(chatsStorage)
  const seen = new Set<string>()
  const rv : Chat[] = []
  for (const chat of lchats) {
    const hash = hashFn(JSON.stringify(chat.messages))
    if (!seen.has(hash)) {
      seen.add(hash)
      rv.push(chat)
    }
    else {
      vlog(`local chat dup (hash) found, name ${chat.name}`)
      if (delete_remote && chat.syncId) {
        withSyncFeature( (cs) => {
          cs.deleteChat(chat.syncId!)
        })
      }
    }
  }
  chatsStorage.set(rv)
}


export function deleteNonchats() {
  const lchats = get(chatsStorage)
  const rv : Chat[] = []
  for (const chat of lchats) {
    if (chat.messages) {
      rv.push(chat)
    } else {
      vlog(`local chat ${chat.syncId} without messages found. deleting it locally.`)
    }
  }
  chatsStorage.set(rv)
}

</script>