<script context="module" lang="ts">
import CryptoJS from 'crypto-js'
import type BaseClient from 'remotestoragejs/release/types/baseclient';

import { DataFormatError, DecryptionError, verror, vlog, vwarn } from './SyncUtil.svelte';
import { LS_ENCRYPTION_KEY_KEY } from './SyncConstants.svelte';

type EncPackage = {
  iv: string,
  ciphertext: string
}

export interface RemoteStorageClientInterface {
  exceptions : Error[]
  data_root : string

  getJsonObject<T>(path: string, addDataRoot?: boolean) : Promise<T>
  getListing(path: string, addDataRoot?: boolean) : Promise<unknown>
  getAll(path: string, addDataRoot?: boolean) : Promise<unknown>
  storeJsonObject<T>(path: string, body: T, addDataRoot?: boolean) : Promise<unknown>
  remove: (path: string, addDataRoot?: boolean) => Promise<unknown>
}


export class RemoteStorageClient implements RemoteStorageClientInterface {
  public exceptions : Error[] = []

  public data_root : string = ""

  constructor(private _rsclient: BaseClient) { }

  private fromRoot(rest:string) : string {
    if (this.data_root != "") {
      if (rest.startsWith('/'))
        return `${this.data_root}${rest}`
      else
        return `${this.data_root}/${rest}`
    }
    throw new Error("data_root not set")
  }

  // returns a string that needs to be json parsed
  private async getJsonString(path: string) : Promise<string> {
    return (this._rsclient.getObject(path) as Promise<EncPackage>).then((encpkg) => {
      try {
        return this.decryptFromJsonObj(encpkg)
      } catch(e) {
        console.error("error decrypting:", e)
        throw new Error(`error decrypting... ${(e as Error).toString()}`)
      }
    }).catch((e) => {
      console.error(`error getting object at path ${path}`, e)
      throw e
    })
  }

  async getJsonObject<T>(path: string, addDataRoot=true) : Promise<T> {
    if (addDataRoot)
      path = this.fromRoot(path)
    return this.getJsonString(path).then((s) => JSON.parse(s) as T) 
  }

  async getListing(path: string, addDataRoot=true) : Promise<unknown> {
    if (addDataRoot)
      path = this.fromRoot(path)
    return this._rsclient.getListing(path).catch((e) => {
      console.error(`error getting listing for path ${path}`, e)
    })
  }

  async getAll(path: string, addDataRoot=true) : Promise<unknown> {
    if (addDataRoot)
      path = this.fromRoot(path)
    vlog(`RemoteStorageClient.getAll(${path})`)
    return this._rsclient.getAll(path, false).then( (dict: any) => {
      const result : any = {}
      for (const [k,v] of Object.entries(dict)) {
        //@ts-ignore
        if (!v.iv || !v.ciphertext) {
          // this is a bug so abort
          throw new DataFormatError(`pre-decryption, expected object with iv and ciphertext fields but got ${v}`)
        }

        let decrypted : string
        try {
          decrypted = this.decryptFromJsonObj(v as EncPackage)
        }
        catch (e) {
          vwarn("note: expected this to be an EncPackage json object: ", v)
          throw new DecryptionError(`error decrypting\n${e}`)
        }

        if (decrypted) {
          try {
            result[k] = JSON.parse(decrypted)
          } catch (e) {
            throw new DataFormatError("post-decryption error parsing json. expected this to be a valid json string: " + decrypted)
          }
        }
      }
      return result
    }).catch( (e) => {
      vwarn("error calling getAll", e)
      this.exceptions.push(e)
    })
  }

  async storeJsonObject<T>(path: string, body: T, addDataRoot=true) : Promise<unknown> {
    if (addDataRoot)
      path = this.fromRoot(path)

    return this.storeJsonString(path, JSON.stringify(body))
  }

  // body should already be stringified json
  private async storeJsonString(path: string, body: string) : Promise<unknown> {
    const encryption_pkg = this.encryptO(body)
    return this._rsclient.storeObject('cryptpkg', path, encryption_pkg)
    // fyi, old way: return this._rsclient.storeFile('application/json', path, encryption_pkg)
  }

  async remove(path: string, addDataRoot=true) : Promise<unknown> {
    if (addDataRoot)
      path = this.fromRoot(path)

    return this._rsclient.remove(path).catch((e: any) => {
      console.warn(`error removing item at path ${path}`, e)
    })
  }

  private getKeyBytes() : CryptoJS.lib.WordArray {
    const keyString = localStorage.getItem(LS_ENCRYPTION_KEY_KEY)!
    if (!keyString) throw new Error("no encryption key found. this shouldn't happen.")
    return CryptoJS.enc.Base64.parse(keyString)
  }

  /*
  takes a utf16 string, i.e. a normal javascript string
  returns json object of the form:
  {  "iv": base64 encoding of random 4-byte initialization vector
     "ciphertext": base64 encoding of ciphertext }
  */
  private encryptO(plaintext: string) : EncPackage {
    if (plaintext === "[object Object]") {
      throw new Error("plaintext is [object Object]. this is a bug.")
    }
    const keyBytes = this.getKeyBytes()
    const iv = CryptoJS.lib.WordArray.random(128 / 8);
    const cryptojsOutput = CryptoJS.AES.encrypt(plaintext, keyBytes, { iv: iv });
    const encPkg : EncPackage = {
      "iv": cryptojsOutput.iv.toString(CryptoJS.enc.Base64),
      "ciphertext": cryptojsOutput.ciphertext.toString(CryptoJS.enc.Base64)
    }
    return encPkg
  }

  private decryptFromJsonObj(encPkg: EncPackage) : string {
    const keyBytes = this.getKeyBytes()
    let ivBytes : CryptoJS.lib.WordArray
    try {
      ivBytes = CryptoJS.enc.Base64.parse(encPkg.iv)
    }
    catch(e) {
      verror(e)
      throw new DataFormatError("error during decryption parsing initialization vector as base 64")
    }

    let ciphertextBytes : CryptoJS.lib.WordArray
    try {
      ciphertextBytes = CryptoJS.enc.Base64.parse(encPkg.ciphertext)
    }
    catch (e) {
      verror(e)
      throw new DataFormatError("error during decryption parsing ciphertext as base 64")
    }

    const decrypt_input = {
      "iv": ivBytes,
      "ciphertext": ciphertextBytes
    }
    let wordarray : CryptoJS.lib.WordArray
    try {
      wordarray = CryptoJS.AES.decrypt(decrypt_input as CryptoJS.lib.CipherParams, keyBytes, { iv: ivBytes });
    }
    catch(e) {
      verror("Error calling CryptoJS.AES.decrypt with input ", decrypt_input)
      throw new DecryptionError(`exception calling CryptoJS.AES.decrypt() with input:\n${decrypt_input}`)
    }

    let rv: string
    try {
        rv = wordarray.toString(CryptoJS.enc.Utf8)
    } catch(e) {
      throw new DataFormatError("error calling wordarray.toString(CryptoJS.enc.Utf8) where wordarray is output of CryptoJS decrypt")
    }
    return rv
  }

  /*
  takes the output of encrypt and
  returns the utf16 string passed to encrypt that yielded json_enc_pkg
  */
  private decrypt(json_enc_pkg: string) : string {
    if (!json_enc_pkg) {
      const msg = "json_enc_pkg is falsy. decrypt's precondition violated. this is a bug."
      console.error(msg)
      throw new Error(msg)
    }
    try {
      let encPkg : EncPackage
      if (typeof json_enc_pkg === 'string') {
        encPkg = JSON.parse(json_enc_pkg) as EncPackage
      }
      else if (typeof json_enc_pkg === 'object'
           && (json_enc_pkg as EncPackage).iv && (json_enc_pkg as EncPackage).ciphertext) {
        vwarn("Accomodating RemoteStorage inconsistency")
        encPkg = json_enc_pkg as EncPackage
      } else {
        console.error("Expected json string or EncPackage object but got ", json_enc_pkg)
        throw new DataFormatError("expected string or EncPackage object.")
      }
      return this.decryptFromJsonObj(encPkg)
    }
    catch(e) {
      vwarn("error parsing json string.", '```' + json_enc_pkg + '```')
      throw e
    }
    throw new Error("unreachable")
  }
}

</script>