<script context="module" lang="ts">

  import CryptoJS from 'crypto-js'

  import RemoteStorage from 'remotestoragejs'
  // @ts:ignore
  import Widget from 'remotestorage-widget'

  import { get } from 'svelte/store'

  import { chatsStorage, deletedChatSyncIdsStorage, deleteChat, addChatFromChat, newChatID, globalStorage, getGlobalSettings } from '../Storage.svelte'
  import type { Chat } from '../Types.svelte'

  import { showProgress, hashFn, syncDebugMode, vlog, vwarn, verror, checkNoFalsey, throttled, RemoteStorageGetAllError } from './SyncUtil.svelte'
  import { v4 as uuidv4 } from 'uuid'
  import type { RemoteStorageClientInterface } from './RemoteStorageClient.svelte'
  import { RemoteStorageClient } from './RemoteStorageClient.svelte';
  import { RS_RANDOM_DATAROOT_KEY, RS_MODTIMES_FOLDER, RS_CHATS_FOLDER, RS_DELETED_CHATS_FOLDER, RS_GLOBAL_MODTIME_KEY} from './SyncConstants.svelte'
  import { LS_REMOTE_RANDOM_DATAROOT_KEY, LS_ENCRYPTION_KEY_KEY, LS_LAST_SYNC_TIME_KEY } from './SyncConstants.svelte'  
  import { ENCPACKAGE_DATATYPE, SALT, SECRET_CODE_LENGTH_CHARS, TIMESTAMP_DATATYPE, } from './SyncConstants.svelte';
  import { showFooterProgress } from './SyncFeatureAPI.svelte';
  import { DROPBOX_APP_KEY, /*GOOGLE_OAUTH_CLIENT_ID*/  } from './SyncConstants.svelte';

  if (navigator.storage && navigator.storage.persist) {
    navigator.storage.persist().then((isPersisted) => {
      console.log(`Persisted storage granted?: ${isPersisted}`);
    })    
  }

  class ChatsDiff {
    constructor(public localOnly: Map<string,Chat>,
                public remoteOnly: string[],
                public bothAndDiffModTimes: Map<string,Chat>,
                public bothAndSameModTimesCnt: number
                ) {}

    size() : number {
      return this.localOnly.size + this.remoteOnly.length + this.bothAndDiffModTimes.size
    }

    stat() : string {
      return (`Chats found:\n` +
              `- On this device only: ${this.localOnly.size}\n` +
              `- On remote server only: ${this.remoteOnly.length}\n` +
              `- On both, with different modification times: ${this.bothAndDiffModTimes.size}\n` +
              `- On both, with same modification time: ${this.bothAndSameModTimesCnt}`)
    }
  }

  /*
  note a RemoteStorage object (i.e. the library) is created by chatgptweb under two conditions:
  - the feature is enabled at startup
  - the feature is enabled in the settings page
  */

  export class ChatsSyncer {
    public rsclient : RemoteStorageClientInterface
    private remoteStorage : RemoteStorage

    private delayedSyncJobId : number = 0
    private syncInProgress = false
    private changedRemote = false

    constructor() {
      this.remoteStorage = new RemoteStorage({
        logging: false,
        //dw: disabled caching (i.e. background syncing) because under some unknown conditions it used localStorage 
        // automatically rather than IndexedDB, which breaks the app when the user has a lot of chats by
        // putting another copy of the chat data in localStorage.
        cache: getGlobalSettings().syncCacheEnabled,
        changeEvents: {
          remote:   true,
          local:    false,
          window:   false,
          conflict: false
        },
        // default is 30000. increased because dropbox backend was timing out for me on getAll for chat modification times
        // doubled again to try to fix intermitent "failed to fetch" issue with RemoteStorage getAll
        requestTimeout: 120000
      })

      this.remoteStorage.setApiKeys({
        dropbox: DROPBOX_APP_KEY,
        // googledrive: GOOGLE_OAUTH_CLIENT_ID
      })

      // See https://remotestoragejs.readthedocs.io/en/latest/getting-started/initialize-and-configure.html#claiming-access
      this.remoteStorage.access.claim('chatgptweb', 'rw')
      if (localStorage.syncRemoteDataPrefix) {
        this.remoteStorage.caching.disable(`/${localStorage.syncRemoteDataPrefix}/chat/`)
      }

      const raw_rsclient = this.remoteStorage.scope('/chatgptweb/')
      raw_rsclient.declareType('timestamp', TIMESTAMP_DATATYPE)
      raw_rsclient.declareType('cryptpkg', ENCPACKAGE_DATATYPE)
      this.rsclient = new RemoteStorageClient(raw_rsclient)

      this.rsclient.data_root = localStorage.getItem(LS_REMOTE_RANDOM_DATAROOT_KEY) || ""

      this.remoteStorage.on('connected', () => {
        this.remoteStorage.startSync()
      })

      // Note to future devs: remoteStorage has connected, disconnected, sync-done, change, etc events that
      // you can register handlers on.
    }

    private registerRemoteChange() {
      this.changedRemote = true
    }

    async syncChats(on_done?: (changed: boolean) => void, retries=5) : Promise<void> {
      vlog("sync requested")

      if (this.syncInProgress) {
        vlog("delaying requested sync because one is already in progress")
        if (this.delayedSyncJobId) {
          window.clearTimeout(this.delayedSyncJobId)
        }
        // check again in 2 seconds
        this.delayedSyncJobId = window.setTimeout(() => {
          if (!this.syncInProgress)
            vlog('running delayed sync')
          this.syncChats(on_done, retries).then(() => {
            this.delayedSyncJobId = 0
          })
        }, 2000)
        return
      }
      else this.syncInProgress = true

      try {
        await this.syncChatsHelper(on_done)
      }
      catch(e:any) {
        verror("syncChats() failed", e)
        this.syncInProgress = false
        this.delayedSyncJobId = 0
        if (retries > 0) {
          if (e.name && e.name === 'RemoteStorageGetAllError') {
            vwarn(`retrying syncChats() because it failed due to getAll error`)
            await this.syncChats(on_done, retries - 1)
          }
          else {
            vwarn(`NOT RETRYING syncChats because it failed for a reason other than getAll error`, e)
          }
        }
        else
          throw e
      }
    }

    private async syncChatsHelper(on_done?: (changed: boolean) => void) : Promise<void> {
      let encryptionKeysOk = false
      await this.rsclient.getJsonObject<string>(RS_RANDOM_DATAROOT_KEY, false).then((arbitrary_val) => {
        encryptionKeysOk = true
      }).catch((e) => {
        verror("Error decrypting data. Probably encryption key mismatch. Aborting sync.", e)
        encryptionKeysOk = false
      })
      if (!encryptionKeysOk) {
        alert("Decryption failed.\nTry again after reloading the page.\nIf problem persists, try First Device Setup or Additional Device Setup.")
        this.syncInProgress = false
        return
      }

      let start = performance.now()

      const remoteDeletedSyncIdsPromise = this.rsclient.getListing(`${RS_DELETED_CHATS_FOLDER}/`).then(async (chat_uuids_object) => {
        return new Set(Object.keys(chat_uuids_object as {}))
      })

      // make sure all local chats have a syncId
      let lchats = get(chatsStorage)
      vlog(`# local chats ${lchats.length}`)
      for (const chat of lchats) {
        if (!chat.syncId) {
          alert("You have chats created while the sync feature was turned off. Accounting for them now to avoid creating duplicates. This is slow, please be patient.")
          await this.assignSyncIdsWithDedup(this.rsclient, lchats)
          break
        }
      }

      const localDeletedSyncIds : Set<string> = new Set(get(deletedChatSyncIdsStorage))
      checkNoFalsey(localDeletedSyncIds, 'localDeletedSyncIds')

      const localChats = new Map<string,Chat>(lchats.map( (chat) => [chat.syncId!, chat] ))
      checkNoFalsey(localChats.keys(), 'old localChats.keys()')

      // ---------------------------------------------
      // Delete local chats that were deleted remotely
      // ---------------------------------------------
      // the list of chat syncids that were deleted remotely
      const remoteDeletedSyncIds = await remoteDeletedSyncIdsPromise
      checkNoFalsey(remoteDeletedSyncIds, 'remoteDeletedSyncIds')
      for (const [syncId, chat] of localChats.entries()) {
        if (remoteDeletedSyncIds.has(syncId)) {
          vlog(`deleting local chat ${syncId}.`)
          deleteChat(chat.id)
          localChats.delete(syncId)
        }
      }

      // note outer syncChats handles exceptions not handled by .catch
      await this.rsclient.getAll(`${RS_MODTIMES_FOLDER}/`)
      .catch( (e) => {
        verror(e)
        this.syncInProgress = false 
      })
      .then(async (modtimesObject) => {

        if (this.rsclient.exceptions.length > 0) {
          verror(`${this.rsclient.exceptions.length} exceptions from RemoteStorage library during getAll:`, this.rsclient.exceptions)
          // RemoteStorageGetAllError will get caught and syncChats retried up to 5 times.
          // For more-sophisticated ways to deal with getAll failures: recall we need 
          // the whole set of modtimes together unless I want to replace localRemoteChatsDiff.
          
          this.syncInProgress = false            
          this.rsclient.exceptions = []
          throw new RemoteStorageGetAllError('')
        }

        const remoteModtimes = new Map((Object.entries((modtimesObject || {}) as any)).map(([k,v]) => [k, (v as any).ts]))

        const chatsDiff = this.localRemoteChatsDiff(localChats, remoteModtimes)
        
        // if there are more than 20 differences, ask the user to confirm
        if (chatsDiff.size() > 20) {
          if( !confirm("More than 20 differences found.\nPlease confirm this looks correct to avoid creating duplicates.\nOtherwise cancel and try sync again.\n" + chatsDiff.stat())) {
            this.syncInProgress = false
            return
          }
        }

        // ---------------------------------------------
        // Delete remote chats that were deleted locally
        // ---------------------------------------------
        for (const deletedSyncId of localDeletedSyncIds) {
          console.assert(!localChats.has(deletedSyncId), `chat ${deletedSyncId} is in local delete set yet still in local chat set`)
          if (!remoteDeletedSyncIds.has(deletedSyncId)) {
            await this.rsclient.storeJsonObject(`${RS_DELETED_CHATS_FOLDER}/${deletedSyncId}`, true).then(() => {
              vlog(`add of locally-deleted ${deletedSyncId} to remote delete set successful`)
              this.registerRemoteChange()
            }).catch((e) => {
              verror(`error adding locally-deleted ${deletedSyncId} to remote delete set`, e)
            })
          }
          if (remoteModtimes!.has(deletedSyncId)) {
            vlog(`deleting chat syncid ${deletedSyncId} from remote modify-time map.`)
            await this.rsclient.remove(`${RS_MODTIMES_FOLDER}/${deletedSyncId}`).then((resp) => {
              vlog(`✓ delete of modtime entry for ${deletedSyncId}`, resp)
              this.registerRemoteChange()
            }).catch((e) => vwarn(`exception deleting remote chat syncid ${deletedSyncId} from modify-time map (maybe it didn't exist)`, e))

            vlog(`deleting chat with syncid ${deletedSyncId} from remote chat map.`)
            await this.rsclient.remove(`${RS_CHATS_FOLDER}/${deletedSyncId}`).then((resp) => {
              vlog(`✓ delete of remote chat syncid ${deletedSyncId}`, resp)
              this.registerRemoteChange()
            }).catch((e) => vwarn(`exception deleting remote chat syncid ${deletedSyncId} (maybe it didn't exist)`, e))
          }
        }

        const totalCountedWork = chatsDiff.remoteOnly.length + chatsDiff.localOnly.size + chatsDiff.bothAndDiffModTimes.size
        let remaining = totalCountedWork

        // --------------------------------
        // Add to local new chats on remote
        // --------------------------------
        for( const syncid of chatsDiff.remoteOnly ) {
          console.assert(!localChats.has(syncid))
          if (!localChats.has(syncid) && !localDeletedSyncIds.has(syncid)) {

            vlog(`fetching and saving new remote chat ${syncid} to local`)            
            await this.rsclient.getJsonObject(`${RS_CHATS_FOLDER}/${syncid}`).then((_rchat) => {
              remaining--  
              const rchat = _rchat as Chat
              if (rchat && rchat.messages /* a quick fallible test that it's a proper Chat object */) {
                const cloned_chat = ({...rchat});
                cloned_chat.id = newChatID()
                addChatFromChat(cloned_chat)
                showFooterProgress(1 - remaining/totalCountedWork, 'new chats on server ⟶ here')
              }
              else {
                verror(`failed to parse object returned when tried to fetch chat with syncId ${syncid} that was in chatsDiff.remoteOnly`)
                vwarn(_rchat)
              }
            }).catch((e) => {
              vwarn(`failed to fetch chat with syncId ${syncid} that was in chatsDiff.remoteOnly`, e)
            })
          }
        }

        // --------------------------------
        // Add to remote new chats on local
        // --------------------------------
        for (const [syncid,lchat] of chatsDiff.localOnly.entries()) {
          const cloned_lchat = ({...lchat});
          // newChatIdWithExclusionSetParam was added to prevent errors from recent asynch changes to localChats
          // that haven't been persisted yet
          cloned_lchat.id = this.newChatIdWithExclusionSetParam(Array.from(localChats.values()))

          vlog(`sending new local chat ${syncid} (local id ${lchat.id}, remote id ${cloned_lchat.id}) to remote`)
          
          await this.rsclient.storeJsonObject(`${RS_CHATS_FOLDER}/${syncid}`, cloned_lchat).then(() => {
            vlog(`\t✓ sent new local chat ${syncid} (local id  ${cloned_lchat.id}) to remote`)
            this.registerRemoteChange()
          }).catch((e) => {
            verror(`error sending new local chat ${syncid} to remote`, e)
          }).finally(() => {
            showProgress('footer-progress-display',1 - remaining/totalCountedWork, 'new chats here  ⟶ server')
            remaining--
          })

          const lastUse = lchat.lastUse || 0
          this.rsclient.storeJsonObject(`${RS_MODTIMES_FOLDER}/${syncid}`, {ts:lastUse} as any).then(() => {
            vlog(`\t✓ update approx modtime for remote chat ${syncid}`)
            this.registerRemoteChange()
          }).catch((e) => {
            verror(`error setting approx mod time for remote chat ${syncid}`, e)
          })          
        }


        const remoteChatFetchPromises : Promise<void>[] = []
        // -------------------------------------
        // Chats that exists both locally and remotely
        // -------------------------------------
        for (const [syncid,lchat] of chatsDiff.bothAndDiffModTimes.entries()) {
          const prom : Promise<void> = this.rsclient.getJsonObject(`${RS_CHATS_FOLDER}/${syncid}`).then( async (_rchat) => {            
            showProgress('footer-progress-display',1 - remaining/totalCountedWork, 'changed chats')
            
            const rchat = _rchat as Chat
            let remoteLastUse = rchat.lastUse

            if (lchat.lastUse > remoteLastUse) {
              const cloned_lchat = ({...lchat});
              cloned_lchat.id = rchat.id
              await this.rsclient.storeJsonObject(`${RS_CHATS_FOLDER}/${syncid}`, cloned_lchat).then(() => {
                vlog(`\t✓ update remote chat object ${syncid}`)
                this.registerRemoteChange()
              })
              
              await this.rsclient.storeJsonObject(`${RS_MODTIMES_FOLDER}/${syncid}`, {ts:lchat.lastUse}).then(() => {
                vlog(`\t✓ update remote modtime for ${syncid}`)
                this.registerRemoteChange()
              })
            }
            else if(lchat.lastUse < remoteLastUse) { // local < remote
              console.warn(`TODO: refresh view if we're on this chat`)
              vlog("\tsaving newer remote to local, but keeping local .id")

              // Could be necessary to get it from persistent storage again since other async calls could have changed the local chats store.
              lchats = get(chatsStorage)
              // find its index in the list localStorage.chats
              const i = lchats.findIndex((lchat2) => {
                return lchat2.syncId == lchat.syncId
              })
              // NBD to change this copy of remote's chat object; don't need to clone.
              rchat.id = lchats[i].id
              lchats[i] = rchat
              chatsStorage.set(lchats)
            } else {
              // this shouldn't happen; lchat shouldn't be in the ChatDiff
              verror(`local chat with title ${lchat.name} exists both locally and remotely, and has the same lastUse time, so shouldn't have reached this code.`)
            }

            remaining--

          }).catch((e) => {
            vwarn(`failed to fetch chat with syncId ${syncid} that was in chatsDiff.localChanged. The exception: `, e)
          })

          await prom
          // with the previous line, use of remoteChatFetchPromises is redundant.
          // I switched to awaiting each as a quick way to deal with rate limitting.
          // so, the `await Promise.all` block below can be simplified. 
          remoteChatFetchPromises.push(prom)
        }
        vlog(`${(performance.now() - start)/1000} seconds for main thread of syncChats`)

        // see note a bit above.
        await Promise.all(remoteChatFetchPromises).then(() => {
          vlog(`${(performance.now() - start)/1000} seconds to finish all syncChats async calls`)
          vlog(`changedRemote is ${this.changedRemote}`)          
          showProgress('footer-progress-display', 1, '')
          
          if (on_done)
            on_done(this.changedRemote)

          this.changedRemote = false

          // not using this anymore, but leaving for debugging
          // localStorage.setItem(LS_LAST_SYNC_TIME_KEY, Date.now().toString())
        })
      })
      .finally(() => {
        if (this.rsclient.exceptions.length > 0) {
          if (!syncDebugMode()) 
            console.log(`${this.rsclient.exceptions.length} exceptions from RemoteStorage library during chats sync`)
          else 
            verror("Exceptions from RemoteStorage library during sync chats:", this.rsclient.exceptions)
          // discard the list of exceptions
          this.rsclient.exceptions = []         
        }
        this.syncInProgress = false
      })
    }

    async updateRemoteModtime() : Promise<any>{
      const t = Date.now()      
      await this.rsclient.storeJsonObject(RS_GLOBAL_MODTIME_KEY, {ts:t}).then(() => {
        vlog("success updating remote global mod time")
      }).catch((e) => {
        verror("error updating remote global mod time", e)
      })
    }

    async getRemoteModtime() : Promise<number> {
      return this.rsclient.getJsonObject(RS_GLOBAL_MODTIME_KEY).then((modtime_obj) => {
        return (modtime_obj as {ts:number}).ts
      })
    }

    newAuthWidget() {
      return new Widget(this.remoteStorage, {autoconnect: true, skipInitial: true})
    }    

    saveEncKeyFromNewCode(code: string) : void {
      if (code.length < SECRET_CODE_LENGTH_CHARS) {
        alert(`Expected code of length at least ${SECRET_CODE_LENGTH_CHARS}`)
        throw new Error(`code length should be at least ${SECRET_CODE_LENGTH_CHARS} but is ${code.length}`)
      }
      const key8bytes = CryptoJS.PBKDF2(code, SALT, { keySize: 256 / 32 })
      const keyString = key8bytes.toString(CryptoJS.enc.Base64)
      localStorage.setItem(LS_ENCRYPTION_KEY_KEY, keyString)      
    }

    async deleteChat(syncId: string) {
      this.rsclient.remove(`${RS_CHATS_FOLDER}/${syncId}`).then(() => {
        vlog(`remote delete of ${syncId} chat object ok (note: not added to delete set)`)
        this.rsclient.remove(`${RS_MODTIMES_FOLDER}/${syncId}`).then(() => {
          vlog(`remote delete of ${syncId} modtime object ok`)
        }).catch((e) => {
          verror(`error deleting remote modtime for ${syncId}`, e)
        })
      }).catch((e) => {
        verror(`error deleting remote chat object ${syncId}`, e)
      })
    }


    private chatPropsForDedup(chat: Chat) : any {
      return {
        "messages": chat.messages,
        "name": chat.name
      }
    }

    /*
    This is for the case where the user has chats on their device that were created before they turned 
    on the sync feature, or while it was temporarily disabled.

    get the set of remote syncIds.
    for each remote syncId, sid:
        request the corresponding Chat, rchat. save the promise.
        then, with response rchat:
            h = hash(rchat)
            check if h is in lhash2chat
            if so, set lhash2chat[h].syncId to sid
    await all of those promises, then
    confirm with user and then do:
        for each local chat that still has no syncid, assign it a fresh random syncid
    finally, persist local chats
    */
    private async assignSyncIdsWithDedup(rsclient: RemoteStorageClientInterface, localChats: Chat[]) {
      vlog("assignSyncIdsWithDedup")
      const localChatsNoSyncId = localChats.filter((localChat: Chat) => { return !localChat.syncId })
      let remaining = localChatsNoSyncId.length
      // map of chat hashes to local chats with no syncId
      const lhash2chat = new Map(localChatsNoSyncId.map((chat) => {
        showProgress('footer-progress-display', 1 - remaining/localChatsNoSyncId.length, 
                     'hashing chats with no sync ids on this device')
        const h = hashFn(JSON.stringify(this.chatPropsForDedup(chat)))
        return [h, chat]
      }))

      let had_syncid_cnt = 0

      // await is used here and elsewhere as a simple hack to avoid rate-limiting
      await rsclient.getListing(`${RS_CHATS_FOLDER}/`).then(async (chat_syncids_object) => {
        let keys = Object.keys(chat_syncids_object as object)
        let remaining = keys.length
        for (const syncid of keys) {
          showProgress('footer-progress-display', 1 - remaining/keys.length, 'checking server for chats in common')
          await rsclient.getJsonObject(`${RS_CHATS_FOLDER}/${syncid}`).then((_rchat) => {
            const rchat = _rchat as Chat
            if (!rchat.messages) {
              throw new Error(`not a chat object!\n${JSON.stringify(rchat)}`)
            }
            const h = hashFn(JSON.stringify(this.chatPropsForDedup(rchat)))
            if (lhash2chat.has(h)) {
              lhash2chat.get(h)!.syncId = syncid
              had_syncid_cnt += 1
            }
          })
          remaining--
        }
      })

      let no_syncid_cnt = 0
      for (const [h,chat] of lhash2chat.entries()) {
        if (!chat.syncId) {
          chat.syncId = uuidv4()
          no_syncid_cnt += 1
        }
      }

      const response = confirm(
        `Ok to add new sync ids to ${no_syncid_cnt} local chats? Of ${localChatsNoSyncId.length} local ` +
        `chats with no sync id, ${had_syncid_cnt} were found on remote, and ${no_syncid_cnt} were not. ` + 
        `Confirming because this could create duplicates.`)
      if (response){
        // this is a little weird because we've been using localChatsNoSyncId, not localChats, but
        // localChatsNoSyncId is just a subset of the reference objects in localChats, which we've been modifying.
        // since we want to keep all the local chats, not only the ones we just assigned syncids, this is
        // the right thing to do.
        chatsStorage.set(localChats)
        vlog(`assignSyncIdsWithDedup: of ${localChatsNoSyncId.length} local chats with no syncid, ${had_syncid_cnt} were found on remote, and ${no_syncid_cnt} were not.`)
      }
    }

    private nextId : number = 1
    private newChatIdWithExclusionSetParam(chats: Chat[]) : number {
      let chatId = chats.reduce((maxId, chat) => Math.max(maxId, chat.id), 0) + 1
      if (!this.nextId) {
        this.nextId = chatId + 1
      }
      else {
        chatId = this.nextId
        this.nextId += 1
      }
      return chatId
    }


    private localRemoteChatsDiff(local_chats: Map<string,Chat>, remote_modtime_estimates: Map<string, number>) : ChatsDiff {
      const localOnly = new Map<string,Chat>()
      const bothAndDiffModTimes = new Map<string,Chat>()
      const remoteOnly : string[] = []
      let bothAndSameCount = 0

      for (const [syncId,chat] of local_chats.entries()) {
        if (!remote_modtime_estimates.has(syncId)) {
          localOnly.set(syncId,chat)
        }
        else if (chat.lastUse != remote_modtime_estimates.get(syncId)!) {
          bothAndDiffModTimes.set(syncId,chat)
        }
        else {
          bothAndSameCount++
        }
      }
      for (const syncId of remote_modtime_estimates.keys()) {
        if (!local_chats.has(syncId)) {
          remoteOnly.push(syncId)
        }
      }
      return new ChatsDiff(localOnly, remoteOnly, bothAndDiffModTimes, bothAndSameCount)
    }
  }

</script>