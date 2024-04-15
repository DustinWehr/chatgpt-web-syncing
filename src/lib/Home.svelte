<script lang="ts">
  import { apiKeyStorage, globalStorage, lastChatId, getChat, started, setGlobalSettingValueByKey, checkStateChange, getGlobalSettings } from './Storage.svelte'
  import Footer from './Footer.svelte'
  import { replace } from 'svelte-spa-router'
  import { afterUpdate, onMount } from 'svelte'
  import { getPetalsBase, getPetalsWebsocket } from './ApiUtil.svelte'
  import { set as setOpenAI } from './providers/openai/util.svelte'
  import { hasActiveModels } from './Models.svelte'
  import { reactiveShowSyncSettings, reactiveHaveShortSyncCode, reactiveJoiningShortSyncCode, reactiveGeneratingShortSyncCode, syncSettingsToggle } from './sync/SyncFeatureAPI.svelte'
  import { showFooterProgress, clearRemoteSyncData, checkRemoteSyncDataCleared, dedupLocalChatsBySyncId, dedupLocalChatsByHash, deleteNonchats, autosyncAfterLocalChangeActive } from './sync/SyncFeatureAPI.svelte'
  import { encSetupToggle, getShortEncryptionCode, clearLocalSyncData, newShortEncryptionCode, acceptNewShortEncryptionCode, updateSyncFeatureSettingsView } from './sync/SyncFeatureAPI.svelte'
  import { maybeLoadSyncFeature, shortEncryptCodeForJoinGroupEntered } from './sync/SyncFeatureAPI.svelte';
  import type { GlobalSettings } from './Types.svelte';

$: apiKey = $apiKeyStorage

let showPetalsSettings = $globalStorage.enablePetals
let pedalsEndpoint = $globalStorage.pedalsEndpoint
let hasModels = hasActiveModels()

onMount(() => {
    if (!$started) {
      $started = true
      // console.log('started', apiKey, $lastChatId, getChat($lastChatId))
      if (hasActiveModels() && getChat($lastChatId)) {
        const chatId = $lastChatId
        $lastChatId = 0
        replace(`/chat/${chatId}`)
      }
    }
    $lastChatId = 0
})

afterUpdate(() => {
    hasModels = hasActiveModels()
    pedalsEndpoint = $globalStorage.pedalsEndpoint
    $checkStateChange++
    updateSyncFeatureSettingsView()
})

const setPetalsEnabled = (event: Event) => {
    const el = (event.target as HTMLInputElement)
    setGlobalSettingValueByKey('enablePetals', !!el.checked)
    showPetalsSettings = $globalStorage.enablePetals
    hasModels = hasActiveModels()
}

const setEnableSyncFeature = (event: Event) => {
  const val = !!(event.target as HTMLInputElement).checked
  setGlobalSettingValueByKey('enableSyncFeature', val)
  maybeLoadSyncFeature()
  updateSyncFeatureSettingsView()
}

// lazy; without any reactive GUI changes
const setBooleanOption = (option_name: keyof GlobalSettings) => {
  return (event: Event) => {
    const val = !!(event.target as HTMLInputElement).checked
    setGlobalSettingValueByKey(option_name, val)
  }
}
</script>

<section class="section">
  <article class="message">
    <div class="message-body">
    <p class="mb-4">
      <strong><a href="https://github.com/Niek/chatgpt-web" target="_blank">ChatGPT-web</a></strong>
      is a simple one-page web interface to the OpenAI ChatGPT API. To use it, you need to register for
      <a href="https://platform.openai.com/account/api-keys" target="_blank" rel="noreferrer">an OpenAI API key</a>
      first. OpenAI bills per token (usage-based), which means it is a lot cheaper than
      <a href="https://openai.com/blog/chatgpt-plus" target="_blank" rel="noreferrer">ChatGPT Plus</a>, unless you use
      more than 10 million tokens per month. All messages are stored in your browser's local storage, so everything is
      <strong>private</strong>. You can also close the browser tab and come back later to continue the conversation.
    </p>
    <p>
      As an alternative to OpenAI, you can also use Petals swarm as a free API option for open chat models like Llama 2. 
    </p>
    </div>
  </article>
  <article class="message" class:is-danger={!hasModels} class:is-warning={!apiKey} class:is-info={apiKey}>
    <div class="message-body">
      Set your OpenAI API key below:

      <form
        class="field has-addons has-addons-right"
        on:submit|preventDefault={(event) => {
          let val = ''
          //@ts-ignore
          if (event.target && event.target[0].value) {
            //@ts-ignore
            val = (event.target[0].value).trim()
          }
          setOpenAI({ apiKey: val })
          hasModels = hasActiveModels()
        }}
      >
        <p class="control is-expanded">
          <input
            aria-label="OpenAI API key"
            type="password"
            autocomplete="off"
            class="input"
            class:is-danger={!hasModels}
            class:is-warning={!apiKey} class:is-info={apiKey}
            value={apiKey}
          />
        </p>
        <p class="control">
          <button class="button is-info" type="submit">Save</button>
        </p>


      </form>

      {#if !apiKey}
        <p class:is-danger={!hasModels} class:is-warning={!apiKey}>
          Please enter your <a target="_blank" href="https://platform.openai.com/account/api-keys">OpenAI API key</a> above to use Open AI's ChatGPT API.
          At least one API must be enabled to use ChatGPT-web.
        </p>
      {/if}
    </div>
  </article>

  
  <article class="message" class:is-danger={!hasModels} class:is-warning={!showPetalsSettings} class:is-info={showPetalsSettings}>
    <div class="message-body">
      <label class="label" for="enablePetals">
        <input 
        type="checkbox"
        class="checkbox" 
        id="enablePetals"
        checked={!!$globalStorage.enablePetals} 
        on:click={setPetalsEnabled}
      >
        Use Petals API and Models (Llama 2)
      </label>
      {#if showPetalsSettings}
        <p>Set Petals API Endpoint:</p>
        <form
          class="field has-addons has-addons-right"
          on:submit|preventDefault={(event) => {
            //@ts-ignore
            if (event.target && event.target[0].value) {
              //@ts-ignore
              const v = event.target[0].value.trim()
              const v2 = v.replace(/^https:/i, 'wss:').replace(/(^wss:\/\/[^/]+)\/*$/i, '$1' + getPetalsWebsocket())
              setGlobalSettingValueByKey('pedalsEndpoint', v2)
              //@ts-ignore
              event.target[0].value = v2
            } else {
              setGlobalSettingValueByKey('pedalsEndpoint', '')
            }
          }}
        >
          <p class="control is-expanded">
            <input
              aria-label="PetalsAPI Endpoint"
              type="text"
              class="input"
              placeholder={getPetalsBase() + getPetalsWebsocket()}
              value={$globalStorage.pedalsEndpoint || ''}
            />
          </p>
          <p class="control">
            <button class="button is-info" type="submit">Save</button>
          </p>

          
        </form>
        
        {#if !pedalsEndpoint}
          <p class="help is-warning">
            Please only use the default public API for testing. It's best to <a target="_blank" href="https://github.com/petals-infra/chat.petals.dev">configure a private endpoint</a> and enter it above for connection to the Petals swarm.
          </p>
        {/if}
        <p class="my-4">
          <a target="_blank" href="https://petals.dev/">Petals</a> lets you run large language models at home by connecting to a public swarm, BitTorrent-style, without hefty GPU requirements.
        </p>
        <p class="mb-4">
          You are encouraged to <a target="_blank" href="https://github.com/bigscience-workshop/petals#connect-your-gpu-and-increase-petals-capacity">set up a Petals server to share your GPU resources</a> with the public swarm. Minimum requirements to contribute Llama 2 completions are a GTX&nbsp;1080&nbsp;8GB, but the larger/faster the better.
        </p>
        <p class="mb-4">
          If you're receiving errors while using Petals, <a target="_blank" href="https://health.petals.dev/">check swarm health</a> and consider <a target="_blank" href="https://github.com/bigscience-workshop/petals#connect-your-gpu-and-increase-petals-capacity">adding your GPU to the swarm</a> to help.
        </p>
        <p class="help is-warning">
          Because Petals uses a public swarm, <b>do not send sensitive information</b> when using Petals.
        </p>
      {/if}
    </div>
  </article>
  {#if apiKey}
    <article class="message is-info">
      <div class="message-body">
        Select an existing chat on the sidebar, or
        <a href={'#/chat/new'}>create a new chat</a>
      </div>
    </article>
  {/if}



  <article class="message">
  <div id='remote-storage-section' class="message-body">
    <!-- Sync feature enabled checkbox -->
    <label class="label" for="syncFeatureEnabledCheckbox">
      <input type="checkbox" class="checkbox" id="syncFeatureEnabledCheckbox"
              checked={getGlobalSettings().enableSyncFeature}
              on:click={setEnableSyncFeature}/>
      Enable syncing between your devices
    </label>

    {#if $globalStorage.enableSyncFeature}
      <b>IMPORTANT NOTES:</b>
      <article class="message-body">
        <p>· This is not a cloud backup for your chats, despite the protocol name "RemoteStorage". You won't be warned before you do something that deletes data stored on a server (which is all encrypted). Even if you use Dropbox, all you'll see is encrypted text files. Only your devices have the encryption keys (stored in your devices' browsers' localStorage).</p>
        <p>· This is not a collaborative editing feature. If the same chat is edited from two linked devices without syncing and refreshing the page, one of those edits will be lost.</p>
        <p>· You need a (free) RemoteStorage or Dropbox account to use the feature, but for Dropbox you need to <a href='https://github.com/Niek/chatgpt-web/issues/364'>ask to have your email added to a list of test users</a> (until I submit the app to Dropbox for approval... which I won't bother doing if only a handful of people ever use the sync feature). </p>
        <!-- <p>------ You need a Remote Storage, Dropbox, or Google Drive account, but for the latter two you need to <a href='https://github.com/Niek/chatgpt-web/issues/364'>ask to have your email added to a list of test users</a> (until I submit the app to Google and Dropbox for approval... which I won't bother doing if only a handful of people ever use the sync feature). </p> -->
        <p>· For RemoteStorage, which is faster and more reliable than Dropbox for this feature, you need an account with a server that implements the RemoteStorage protocol.
           <a href='https://5apps.com/storage'>5apps.com is currently offering free accounts</a>.</p>
        <!-- <p>------ Google Drive requires more permissions than it should. Only use it with a google account whose Drive space you don't use for anything else.</p>         -->
      </article>

      <div id='remote-storage-widget-container'></div>
      <!-- remoteStorage connect widget inserted here. -->

      <button class="button is-info"
        on:click={() => syncSettingsToggle()}>
        Sync Settings</button>
      <p/>
      <br/>

      {#if $reactiveShowSyncSettings}

        <!-- Autosync-after-change checkbox -->
        <label class="label" for="autosyncAfterChangeActiveCheckbox">
          <input type="checkbox" class="checkbox" id="autosyncAfterChangeActiveCheckbox"
                  checked={autosyncAfterLocalChangeActive()}
                  on:click={setBooleanOption('autosyncAfterLocalChange')}/>
          Do a sync after every change you make from this device.
        </label>




        <span class="label">Encryption</span>
        <article id='remote-storage-encryption-section' class="message-body">

          <p>· Sync requires a random secret code for end-to-end encryption of your chats. You generate it on one device and enter it on the others.<p/>
          <p>· We don't encrypt chats on your devices; this encryption only ensures nobody can read it when it's NOT on your devices.</p>
          <br/>

          {#if $reactiveHaveShortSyncCode}
          <p>
            <span class="label">
              Hover to show current code to copy to another device:
              <span id="sync-code-display-parent">
                <span id="sync-code-display" style="padding-left: 2%; padding-right: 2%">
                  {getShortEncryptionCode( )}
                </span>
              </span>
            </span>
          </p><br/>
          {/if}



          <p>
            <button class="button is-info"
                    on:click={() => encSetupToggle(true)}>
              First Device Setup</button>
            <button class="button is-info"
                    on:click={() => encSetupToggle(false)}>
              Additional Device Setup</button>
          </p> <br/>

          {#if $reactiveJoiningShortSyncCode}
            <label class="label" for="short-encrypt-code-join-input">
              Code created on another device
            </label>
            <form
              class="field has-addons has-addons-right"
              on:submit|preventDefault={(event) => {
                //@ts-ignore
                const inputval = event.target[0].value
                if (event.target && inputval) {
                  shortEncryptCodeForJoinGroupEntered(inputval)
                }
              }}>
              <p class="control is-expanded">
                <input id="short-encrypt-code-join-input"
                        aria-label="Short encryption code created on another device"
                        autocomplete="off"
                        value={getShortEncryptionCode() || ""}
                        size=70 type="text" class="input"/>
              </p>
              <p class="control is-expanded">
                <button id='save-existing-enc-code-button' class="button is-info" type="submit">
                  Save
                </button>
              </p>
            </form>
          {/if}

          {#if $reactiveGeneratingShortSyncCode}
            <label class="label" for="new-short-encryption-code-cell">
              Generate new code
            </label>

            <div class="control">
              <button class="button is-info" type="button"
                on:click={(event) => {
                  const inputelem = document.getElementById('new-short-encryption-code-cell')
                  //@ts-ignore
                  // replace input with new random code
                  if (inputelem) inputelem.value = newShortEncryptionCode()
              }}>
                Generate New
              </button>


              <div id='new-code-controls' >
                <input id="new-short-encryption-code-cell"
                  readonly
                  aria-label="end-to-end encryption code"
                  type="text"
                  autocomplete="off"
                  class="input"
                  value={getShortEncryptionCode() || ""}
                />

                <button id='cancel-change-enc-key-button' class="button is-info" type="button"
                  on:click={(event) => {
                    //@ts-ignore
                    document.getElementById('new-short-encryption-code-cell').value = ""
                    encSetupToggle(true)
                }}>
                  Cancel
                </button>

                <button id='accept-change-enc-key-button' class="button is-info" type="submit"
                  on:click={(event) => {
                    const inputelem = document.getElementById('new-short-encryption-code-cell')
                    // todo: I think this is unnecessary since encSetupToggle() changes reactive variables, so the input 
                    // (given the template elsewhere in this file) will be recreated with this initial value
                    if (document.getElementById('sync-code-display')) {
                      //@ts-ignore
                      document.getElementById('sync-code-display').value = inputelem.value
                    }

                    //@ts-ignore
                    acceptNewShortEncryptionCode(inputelem.value)
                    encSetupToggle(true)
                }}>
                  Accept
                </button>
              </div>
            </div>

          {/if}

          </article>


          <span class="label">Troubleshooting</span>

          <article id='sync-troubleshooting-section' class="message-body">

            <p>Please report any bugs with sync! But for immediate relief, you can try these buttons.</p>
          
            <p><b>These won't delete any of the chats on your devices:</b></p>

            <!-- Clear remoteStorage button -->
            <button class="button is-info"
              on:click={(event) => {
                if (confirm("This takes a while to avoid rate-limiting.\nIf you have a lot of chats, it'll take a while to reupload them.")) {
                  clearRemoteSyncData('/', async () => {
                    // showProgress('clearing-progress-display')
                    showFooterProgress(1, 'clearing encrypted chats on server')
                    const remaining = await checkRemoteSyncDataCleared()
                    if (remaining > 0) {
                      alert(`failed to clear all remote sync data!\n${remaining} values remaining.\nplease try again.`)
                      return
                    }
                  }, 
                  // (x) => showProgress('clearing-progress-display',x))
                  (x) => showFooterProgress(x, 'clearing encrypted chats on server'))
                }
              }}>
              Clear remote sync data 
              <span id="clearing-progress-display"></span>
            </button>

            <!-- Reset local sync bookkeeping button -->
            <button class="button is-info"
              on:click={(event) => {
                if (confirm("You'll need to re-enter your short sync code from another device, or make a new one.")) {
                  clearLocalSyncData()
                }
              }}
            >Reset local sync bookkeeping data</button>

            {#if $globalStorage.syncDebugMode}

            <p><b>These CAN delete chats on this device:</b></p>

            <button class="button is-info"
              on:click={(event) => {
                dedupLocalChatsBySyncId()
              }}
            >Dedup local chats by syncId</button>
            <button class="button is-info"
              on:click={(event) => {
                dedupLocalChatsByHash(true)
              }}
            >Dedup local chats by hash</button>
            <button class="button is-info"
            on:click={(event) => {
              deleteNonchats()
            }}
            >Delete corrupt local chats</button>

            {/if}
        </article>

        <label class="label" for="syncDebugModeCheckbox">
          <input type="checkbox" class="checkbox" id="syncDebugModeCheckbox"
                  checked={getGlobalSettings().syncDebugMode}
                  on:click={setBooleanOption('syncDebugMode')}/>
          Verbose logging and extra troubleshooting buttons.
        </label>
      {/if}
    {/if}
  </div>
  </article>

  <article class="message">
    <div id='misc-boolean-options-section' class="message-body">
      <!-- misc boolean options -->
      <label class="label" for="toggleAutoSummarizeCheckbox">
        <input type="checkbox" class="checkbox" id="toggleAutoSummarizeCheckbox"
                checked={getGlobalSettings().autoSummarize}
                on:click={setBooleanOption('autoSummarize')}/>
        Automatically summarize chats
      </label>
      <label class="label" for="toggleMultipleNewChatButtons">
        <input type="checkbox" class="checkbox" id="toggleMultipleNewChatButtons"
                checked={getGlobalSettings().multipleNewChatButtons}
                on:click={setBooleanOption('multipleNewChatButtons')}/>
        New chat shortcut buttons
      </label>
    </div>    
  </article> 
</section>
<Footer pin={true} />