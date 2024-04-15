<script  context="module" lang="ts">
import { get } from 'svelte/store'
import {enc, SHA1} from 'crypto-js';
import { chatsStorage, getGlobalSettings } from '../Storage.svelte';

export class EncodingError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "EncodingError";
  }
}

export class DataFormatError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "DataFormatError";
  }
}

export class DecryptionError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "DecryptionError";
  }
}

export class RemoteStorageGetAllError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "RemoteStorageGetAllError";
  }
}

export const syncDebugMode = () => {  
  return getGlobalSettings().syncDebugMode
}

export const vwarn = (...args: any[]) => {
  if (syncDebugMode()) {
    console.warn(...args)
  }
}

export const vlog = (...args: any[]) => {
  if (syncDebugMode()) {
    console.log(...args)
  }
}

export const verror = (...args: any[]) => {
  if (syncDebugMode()) {
    console.error(...args)
  }
}

export const hashFn = (s: string): string => {
  const wordArray = enc.Utf8.parse(s);
  return SHA1(wordArray).toString();
}

export const fixIds = () => {
  const chats = get(chatsStorage)
  for (let i = 1; i <= chats.length; i++) {
    chats[i].id = i
  }
  chatsStorage.set(chats)
}

export const clearLocalStorageCaching = () => {
  for (let key in localStorage) {
    if (key.startsWith("remotestorage:cache")) {
        delete localStorage[key]
    }
  }
}


export const checkNoFalsey = (iter: Iterable<string | undefined>, name:string) => {
  for (const x of iter) {
    if (!x) {
      console.error(`Iterable ${name} contains a falsey value and shouldn't`)
      throw new Error(`Iterable ${name} contains a falsey value and shouldn't`)
    }
  }
}

// can optimize later if desired
export class Queue<T> {
  private q: T[] = []

  constructor() {}

  push(x: T) {
    this.q.push(x)
  }

  pop() : T | undefined {
    return this.q.shift()
  }

  size() : number {
    return this.q.length
  }
}

export function throttled(deferreds: (() => Promise<void>)[],
                         gapBetweenCalls: number = 1000,
                         whenDone?: () => void,
                         progressFeedback?: (fraction: number) => void) {
  const q = new Queue<() => Promise<void>>()

  for (const f of deferreds) {
    q.push(() => f())
  }

  const promises : Promise<void>[] = []

  const jobid = window.setInterval(async () => {
    const task = q.pop()
    if (task) {
      promises.push(task().then(() => {
        if (progressFeedback)
          progressFeedback(1 - q.size() / deferreds.length)
        if (q.size() > 0)
          vlog(`${q.size()} tasks remain in queue`)
      }))
    }
    else {
      vwarn(`queue empty. so all tasks should be started. clearing interval job.`)
      clearInterval(jobid)
      if (whenDone) {
        vwarn(`awaiting all task finishing`)
        // alert('where are we with the progress indicator?')
        await Promise.all(promises)
        vwarn(`calling whenDone() param`)
        whenDone()
      }
    }
  }, gapBetweenCalls)

  return jobid

}


export function showProgress(elementid: string, fraction: number|null, text: string) : void {
  const elem = document.getElementById(elementid)!
  const val = Math.round((fraction || 1) * 100)
  if (val < 100) {
    elem.innerHTML = `${text} ${val}%`
  } else {
    elem.innerHTML = ''
  }
}

// doesn't belong in SyncUtil.svelte, but leaving commented out because it might
// be useful to someone to run from the web console.
// meant to be run from web console only. it's a hack.
// @ts-ignore
// window.suggestAllNames = async () => {
//   const chatItemNames = document.querySelectorAll('span.chat-item-name'); // Select all span nodes with the class .chat-item-name

//   for (let u of chatItemNames) {
//     if (/Chat\s\d+/.test(u.textContent || "")) { // If the text of u matches the regex "Chat\s\d+"
//       (u as any).click(); // Click u
//       await new Promise(resolve => setTimeout(resolve, 2000)); // Wait 2 seconds

//       const v = document.querySelector("[title='Suggest a chat name']"); // Find the node matching the css selector
//       if (v) {
//           (v as any).click(); // Click v
//           await new Promise(resolve => setTimeout(resolve, 3000)); // Wait 3 seconds
//       }
//     }
//   }
// }


</script>