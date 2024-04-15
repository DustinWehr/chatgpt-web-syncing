<script lang="ts">
  import Fa from 'svelte-fa/src/fa.svelte'
  import {
    faGear,
    faTrash,
    faClone,
    // faEllipsisVertical,
    faEllipsis,
    faDownload,
    faUpload,
    faEraser,
    faRotateRight,
    faSquarePlus,
    faKey,
    faFileExport,
    faTrashCan,
    faEye,
    faEyeSlash
  } from '@fortawesome/free-solid-svg-icons/index'
  import { faSquareMinus, faSquarePlus as faSquarePlusOutline } from '@fortawesome/free-regular-svg-icons/index'
  import { addChatFromJSON, chatsStorage, checkStateChange, clearChats, clearMessages, copyChat, globalStorage, setGlobalSettingValueByKey, showSetChatSettings, pinMainMenu, getChat, deleteChat, saveChatStore, saveCustomProfile } from './Storage.svelte'
  import { exportAsMarkdown, exportChatAsJSON, exportAllChatsAsJSON } from './Export.svelte'
  import { newNameForProfile, restartProfile } from './Profiles.svelte'
  import { replace } from 'svelte-spa-router'
  import { clickOutside } from 'svelte-use-click-outside'
  import { openModal } from 'svelte-modals'
  import PromptConfirm from './PromptConfirm.svelte'
  import { startNewChatWithWarning, startNewChatFromChatId, errorNotice, encodeHTMLEntities } from './Util.svelte'
  import type { Chat, ChatSettings } from './Types.svelte'
  import { hasActiveModels } from './Models.svelte'
  import { get as getStore } from 'svelte/store'
  import { newChatID, updateChatSettings } from './Storage.svelte'

  import {enc, SHA1} from 'crypto-js';

  function hashIt(s: string): string {
      const wordArray = enc.Utf8.parse(s);
      return SHA1(wordArray).toString();
  }



  export let chatId : number
  export const show = (showHide:boolean = true) => {
    showChatMenu = showHide
  }
  export let style: string = 'is-right'

  $: sortedChats = $chatsStorage.sort((a, b) => b.id - a.id)

  let showChatMenu = false
  let chatFileInput
  let manyChatsFileInput
  let profileFileInput

  const importChatFromFile = (e) => {
    close()
    const image = e.target.files[0]
    e.target.value = null
    const reader = new FileReader()
    reader.readAsText(image)
    reader.onload = e => {
      const json = (e.target || {}).result as string
      addChatFromJSON(json)
    }
  }

  const importManyChatsFromFile = async (e) => {
    close()
    const chatsStore = getStore(chatsStorage)

    const existingHashes = new Set()

    chatsStore.forEach( (chat, index) => {
      const msgs_string = JSON.stringify(chat.messages);
      existingHashes.add(hashIt(msgs_string));
    })

    function chatExists(chat:Chat) {
      const msgs_string = JSON.stringify(chat.messages);
      return existingHashes.has(hashIt(msgs_string));
    }

    const image = e.target.files[0]
    e.target.value = null
    const reader = new FileReader()
    let not_skipped = 0
    let skipped = 0
    reader.readAsText(image)
    reader.onload = e => {
      const json = (e.target || {}).result as string
      const chats = JSON.parse(json) as Chat[]
      for (let chat of chats) {
        if (!chat.settings || !chat.messages || isNaN(chat.id)) {
          errorNotice('Not valid Chat JSON')
          return 0
        }

        if (chatExists(chat)) {
          // console.log("Skipping import of chat with messages same as an existing chat.")
          skipped += 1
          continue
        }
        not_skipped += 1

        const chatId = newChatID()

        chat.id = chatId
        // dw: note addChatFromJSON overwrites the date in the equivalent place,
        // with chat.created = Date.now(). not sure why.
        chatsStore.push(chat)

        // dw: I'm not sure about this (also in addChatFromJSON). Might be an old-to-new version hack.
        // updateChatSettings(chat.id)
      }
      console.log(`${not_skipped} chats imported. ${skipped} chats skipped.`)

      chatsStorage.set(chatsStore)
    }
  }

  const delChat = () => {
    close()
    openModal(PromptConfirm, {
      title: 'Delete Chat',
      message: 'Are you sure you want to delete this chat?',
      class: 'is-warning',
      confirmButtonClass: 'is-warning',
      confirmButton: 'Delete Chat',
      onConfirm: () => {
        const thisChat = getChat(chatId)
        const thisIndex = sortedChats.indexOf(thisChat)
        const prevChat = sortedChats[thisIndex - 1]
        const nextChat = sortedChats[thisIndex + 1]
        const newChat = nextChat || prevChat
        if (!newChat) {
          // No other chats, clear all and go to home
          replace('/').then(() => { deleteChat(chatId) })
        } else {
          // Delete the current chat and go to the max chatId
          replace(`/chat/${newChat.id}`).then(() => { deleteChat(chatId) })
        }
      }
    })
  }

  const confirmClearChats = () => {
    if (!sortedChats.length) return
    close()
    openModal(PromptConfirm, {
      title: 'Delete ALL Chat',
      message: 'Are you sure you want to delete ALL of your chats?',
      class: 'is-danger',
      confirmButtonClass: 'is-danger',
      confirmButton: 'Delete ALL',
      onConfirm: () => {
        replace('/').then(() => { deleteChat(chatId) })
        clearChats()
      }
    })
  }

  const close = () => {
    $pinMainMenu = false
    showChatMenu = false
  }

  const restartChatSession = () => {
    close()
    restartProfile(chatId)
    $checkStateChange++ // signal chat page to start profile
  }

  const toggleHideSummarized = () => {
    close()
    setGlobalSettingValueByKey('hideSummarized', !$globalStorage.hideSummarized)
  }

  const clearUsage = () => {
    openModal(PromptConfirm, {
      title: 'Clear Chat Usage',
      message: 'Are you sure you want to clear your token usage stats for the current chat?',
      class: 'is-warning',
      confirmButtonClass: 'is-warning',
      confirmButton: 'Clear Usage',
      onConfirm: () => {
        const chat = getChat(chatId)
        chat.usage = {}
        saveChatStore()
      }
    })
  }

  const importProfileFromFile = (e) => {
    const image = e.target.files[0]
    e.target.value = null
    const reader = new FileReader()
    reader.onload = e => {
      const json = (e.target || {}).result as string
      try {
        const profile = JSON.parse(json) as ChatSettings
        profile.profileName = newNameForProfile(profile.profileName || '')
        profile.profile = null as any
        saveCustomProfile(profile)
        openModal(PromptConfirm, {
          title: 'Profile Restored',
          class: 'is-info',
          message: 'Profile restored as:<br><strong>' + encodeHTMLEntities(profile.profileName) +
            '</strong><br><br>Start new chat with this profile?',
          asHtml: true,
          onConfirm: () => {
            startNewChatWithWarning(chatId, profile)
          },
          onCancel: () => {}
        })
      } catch (e:any) {
        errorNotice('Unable to import profile:', e)
      }
    }
    reader.onerror = e => {
      errorNotice('Unable to import profile:', new Error('Unknown error'))
    }
    reader.readAsText(image)
  }

</script>

<div class="dropdown {style}" class:is-active={showChatMenu} use:clickOutside={() => { showChatMenu = false }}>
  <div class="dropdown-trigger">
    <button class="button is-ghost default-text" aria-haspopup="true" 
      aria-controls="dropdown-menu3" 
      on:click|preventDefault|stopPropagation={() => { showChatMenu = !showChatMenu }}
      >
      <span class="icon "><Fa icon={faEllipsis}/></span>
    </button>
  </div>
  <div class="dropdown-menu" id="dropdown-menu3" role="menu">
    <div class="dropdown-content">
      <a href={'#'} class="dropdown-item" class:is-disabled={!chatId} on:click|preventDefault={() => { if (chatId) close(); $showSetChatSettings = true }}>
        <span class="menu-icon"><Fa icon={faGear}/></span> Chat Profile Settings
      </a>
      <hr class="dropdown-divider">
      <a href={'#'} class:is-disabled={!hasActiveModels()} on:click|preventDefault={() => { hasActiveModels() && close(); hasActiveModels() && startNewChatWithWarning(chatId) }} class="dropdown-item">
        <span class="menu-icon"><Fa icon={faSquarePlus}/></span> New Chat from Default
      </a>
      <a href={'#'} class:is-disabled={!chatId} on:click|preventDefault={() => { chatId && close(); chatId && startNewChatFromChatId(chatId) }} class="dropdown-item">
        <span class="menu-icon"><Fa icon={faSquarePlusOutline}/></span> New Chat from Current
      </a>
      <a href={'#'} class="dropdown-item" class:is-disabled={!chatId} on:click|preventDefault={() => { if (chatId) close(); copyChat(chatId) }}>
        <span class="menu-icon"><Fa icon={faClone}/></span> Clone Chat
      </a>
      <hr class="dropdown-divider">
      <a href={'#'} class="dropdown-item" class:is-disabled={!chatId} on:click|preventDefault={() => { if (chatId) restartChatSession() }}>
        <span class="menu-icon"><Fa icon={faRotateRight}/></span> Restart Chat Session
      </a>
      <a href={'#'} class="dropdown-item" class:is-disabled={!chatId} on:click|preventDefault={() => { if (chatId) close(); clearMessages(chatId) }}>
        <span class="menu-icon"><Fa icon={faEraser}/></span> Clear Chat Messages
      </a>
      <a href={'#'} class="dropdown-item" class:is-disabled={!chatId} on:click|preventDefault={() => { if (chatId) close(); clearUsage() }}>
        <span class="menu-icon"><Fa icon={faSquareMinus}/></span> Clear Chat Usage
      </a>
      <hr class="dropdown-divider">
      <a href={'#'} class="dropdown-item" on:click|preventDefault={() => { close(); exportAllChatsAsJSON() }}>
        <span class="menu-icon"><Fa icon={faDownload}/></span> Backup all chats JSON
      </a>
      <a href={'#'} class="dropdown-item" on:click|preventDefault={() => { if (chatId) close(); manyChatsFileInput.click() }}>
        <span class="menu-icon"><Fa icon={faUpload}/></span> Restore many chats JSON
      </a>

      <a href={'#'} class="dropdown-item" class:is-disabled={!chatId} on:click|preventDefault={() => { close(); exportChatAsJSON(chatId) }}>
        <span class="menu-icon"><Fa icon={faDownload}/></span> Backup Chat JSON
      </a>
      <a href={'#'} class="dropdown-item" class:is-disabled={!hasActiveModels()} on:click|preventDefault={() => { if (chatId) close(); chatFileInput.click() }}>
        <span class="menu-icon"><Fa icon={faUpload}/></span> Restore Chat JSON
      </a>
      <a href={'#'} class="dropdown-item" class:is-disabled={!chatId} on:click|preventDefault={() => { if (chatId) close(); exportAsMarkdown(chatId) }}>
        <span class="menu-icon"><Fa icon={faFileExport}/></span> Export Chat Markdown
      </a>
      <hr class="dropdown-divider">
      <a href={'#'} class="dropdown-item" class:is-disabled={!hasActiveModels()} on:click|preventDefault={() => { if (chatId) close(); profileFileInput.click() }}>
        <span class="menu-icon"><Fa icon={faUpload}/></span> Restore Profile JSON
      </a>
      <hr class="dropdown-divider">
      <a href={'#'} class="dropdown-item" class:is-disabled={!chatId} on:click|preventDefault={() => { if (chatId) close(); delChat() }}>
        <span class="menu-icon"><Fa icon={faTrash}/></span> Delete Chat {#if $globalStorage.enableSyncFeature} (synced){/if}
      </a>
      <a href={'#'} class="dropdown-item" class:is-disabled={$chatsStorage && !$chatsStorage[0]} on:click|preventDefault={() => { confirmClearChats() }}>
        <span class="menu-icon"><Fa icon={faTrashCan}/></span> Delete ALL Chats {#if $globalStorage.enableSyncFeature}(not synced){/if}
      </a>
      <hr class="dropdown-divider">
      <a href={'#'} class="dropdown-item" on:click|preventDefault={() => { if (chatId) toggleHideSummarized() }}>
        {#if $globalStorage.hideSummarized}
        <span class="menu-icon"><Fa icon={faEye}/></span> Show Summarized Messages
        {:else}
        <span class="menu-icon"><Fa icon={faEyeSlash}/></span> Hide Summarized Messages
        {/if}
      </a>
      <hr class="dropdown-divider">
      <a href={'#/'} class="dropdown-item" on:click={close}>
        <span class="menu-icon"><Fa icon={faKey}/></span> API Setting
      </a>
    </div>
  </div>
</div>

<input style="display:none" type="file" accept=".json" on:change={(e) => importManyChatsFromFile(e)} bind:this={manyChatsFileInput} >
<input style="display:none" type="file" accept=".json" on:change={(e) => importChatFromFile(e)} bind:this={chatFileInput} >
<input style="display:none" type="file" accept=".json" on:change={(e) => importProfileFromFile(e)} bind:this={profileFileInput} >
