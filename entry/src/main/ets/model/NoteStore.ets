import { common, contextConstant } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Note, localIso, newNoteId, parseNoteList } from './NoteTypes';

const DOMAIN: number = 0x4C4E;
const TAG: string = 'NoteStore';
const FILE_NAME: string = 'lakeside-notes.json';
const STORE_LABEL: string = 'el5/files/lakeside-notes.json';
const PREF_NAME: string = 'lakeside-notes';
const SEEDED_KEY: string = 'seeded';

class SeedFlag {
  known: boolean = false;
  seeded: boolean = false;
}

export class NoteStore {
  private static chain: Promise<void> = Promise.resolve();
  private static movedToEl5: boolean = false;
  private static el5Root: string = '';
  private static el2Root: string = '';

  static storeLabel(): string {
    return STORE_LABEL;
  }

  static readCurrent(ctx: common.UIAbilityContext): Note[] {
    try {
      return NoteStore.parseFile(NoteStore.notePath(ctx));
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'read current %{public}s', JSON.stringify(err));
      return [];
    }
  }

  static load(ctx: common.UIAbilityContext): Promise<Note[]> {
    return NoteStore.enqueue(() => {
      return NoteStore.readNotes(ctx);
    });
  }

  static save(ctx: common.UIAbilityContext, notes: Note[]): Promise<boolean> {
    return NoteStore.enqueue(() => {
      try {
        let written = NoteStore.replaceFile(NoteStore.notePath(ctx), JSON.stringify(notes));
        return Promise.resolve(written);
      } catch (err) {
        hilog.error(DOMAIN, TAG, 'save path %{public}s', JSON.stringify(err));
        return Promise.resolve(false);
      }
    });
  }

  static count(notes: Note[]): number {
    return notes.length;
  }

  static seedIfNeeded(ctx: common.UIAbilityContext): Promise<void> {
    return NoteStore.enqueue(() => {
      return NoteStore.seedBody(ctx);
    });
  }

  static clear(ctx: common.UIAbilityContext): Promise<boolean> {
    return NoteStore.enqueue(() => {
      return NoteStore.clearBody(ctx);
    });
  }

  private static enqueue<T>(work: () => Promise<T>): Promise<T> {
    let recovered = NoteStore.chain.then((): void => {
      return;
    }).catch((): void => {
      return;
    });
    let run = recovered.then<T>((): Promise<T> => {
      return work();
    });
    NoteStore.chain = run.then((): void => {
      return;
    }).catch((): void => {
      return;
    });
    return run;
  }

  private static async readNotes(ctx: common.UIAbilityContext): Promise<Note[]> {
    try {
      return NoteStore.parseFile(NoteStore.notePath(ctx));
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'load %{public}s', JSON.stringify(err));
      return [];
    }
  }

  private static async seedBody(ctx: common.UIAbilityContext): Promise<void> {
    let flag = await NoteStore.readSeededFlag(ctx);
    let path = NoteStore.notePath(ctx);
    if (flag.known && flag.seeded) {
      return;
    }
    if (!flag.known && NoteStore.exists(path)) {
      hilog.error(DOMAIN, TAG, 'seed flag unreadable, keep existing file');
      return;
    }
    let hadFile = NoteStore.exists(path);
    let written = NoteStore.replaceFile(path, JSON.stringify(NoteStore.seedNotes()));
    if (!written) {
      hilog.error(DOMAIN, TAG, 'seed write failed');
      return;
    }
    let marked = await NoteStore.writeSeeded(ctx, true);
    if (marked) {
      return;
    }
    hilog.error(DOMAIN, TAG, 'seed flag failed');
    if (flag.known && !hadFile) {
      NoteStore.removeIfPresent(path);
    }
  }

  private static async clearBody(ctx: common.UIAbilityContext): Promise<boolean> {
    let flag = await NoteStore.readSeededFlag(ctx);
    if (!flag.known) {
      hilog.error(DOMAIN, TAG, 'clear flag unreadable');
      return false;
    }
    if (!await NoteStore.writeSeeded(ctx, false)) {
      return false;
    }
    if (NoteStore.clearFiles(ctx)) {
      return true;
    }
    await NoteStore.writeSeeded(ctx, flag.seeded);
    return false;
  }

  private static async readSeededFlag(ctx: common.UIAbilityContext): Promise<SeedFlag> {
    let flag = new SeedFlag();
    try {
      let pref = await preferences.getPreferences(ctx, PREF_NAME);
      let value = await pref.get(SEEDED_KEY, false);
      flag.known = true;
      flag.seeded = value === true;
      return flag;
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'seed read %{public}s', JSON.stringify(err));
      return flag;
    }
  }

  private static async writeSeeded(ctx: common.UIAbilityContext, seeded: boolean): Promise<boolean> {
    try {
      let pref = await preferences.getPreferences(ctx, PREF_NAME);
      await pref.put(SEEDED_KEY, seeded);
      await pref.flush();
      return true;
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'seed write flag %{public}s', JSON.stringify(err));
      return false;
    }
  }

  private static parseFile(path: string): Note[] {
    if (!NoteStore.exists(path)) {
      return [];
    }
    let text = '';
    try {
      text = fileIo.readTextSync(path).trim();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'read %{public}s', JSON.stringify(err));
      return [];
    }
    if (text.length === 0) {
      return [];
    }
    return parseNoteList(text);
  }

  private static seedNotes(): Note[] {
    let stamp = localIso(new Date());
    let used: string[] = [];
    let notes: Note[] = [];
    notes.push(NoteStore.makeNote(used, '买菜清单', '鸡蛋、青菜、米', stamp));
    notes.push(NoteStore.makeNote(used, '会议室 Wi-Fi', '访客网络，密码写在白板', stamp));
    notes.push(NoteStore.makeNote(used, '家用门锁重置码（演示数据）', '4821-6673-0915', stamp));
    return notes;
  }

  private static makeNote(used: string[], title: string, body: string, stamp: string): Note {
    let note = new Note();
    note.id = NoteStore.newId(used);
    note.title = title;
    note.body = body;
    note.pinned = false;
    note.createdAt = stamp;
    note.updatedAt = stamp;
    return note;
  }

  private static newId(used: string[]): string {
    return newNoteId(used);
  }

  private static notePath(ctx: common.UIAbilityContext): string {
    NoteStore.moveEl2ToEl5(ctx);
    return NoteStore.areaFile(ctx, contextConstant.AreaMode.EL5);
  }

  private static areaFile(ctx: common.UIAbilityContext, area: contextConstant.AreaMode): string {
    return NoteStore.areaRoot(ctx, area) + '/' + FILE_NAME;
  }

  private static areaRoot(ctx: common.UIAbilityContext, area: contextConstant.AreaMode): string {
    if (area === contextConstant.AreaMode.EL5 && NoteStore.el5Root.length > 0) {
      return NoteStore.el5Root;
    }
    if (area === contextConstant.AreaMode.EL2 && NoteStore.el2Root.length > 0) {
      return NoteStore.el2Root;
    }
    let root = ctx.createAreaModeContext(area).filesDir;
    if (area === contextConstant.AreaMode.EL5) {
      NoteStore.el5Root = root;
    } else if (area === contextConstant.AreaMode.EL2) {
      NoteStore.el2Root = root;
    }
    return root;
  }

  private static moveEl2ToEl5(ctx: common.UIAbilityContext): void {
    if (NoteStore.movedToEl5) {
      return;
    }
    let el5 = NoteStore.areaFile(ctx, contextConstant.AreaMode.EL5);
    let el2 = NoteStore.areaFile(ctx, contextConstant.AreaMode.EL2);
    if (!NoteStore.exists(el5) && NoteStore.exists(el2)) {
      let text = '';
      try {
        text = fileIo.readTextSync(el2);
      } catch (err) {
        hilog.error(DOMAIN, TAG, 'el5 copy %{public}s', JSON.stringify(err));
        return;
      }
      if (!NoteStore.replaceFile(el5, text)) {
        hilog.error(DOMAIN, TAG, 'el5 copy write failed');
        return;
      }
    }
    if (NoteStore.exists(el5)) {
      NoteStore.removeIfPresent(el2);
      NoteStore.removeIfPresent(el2 + '.tmp');
      NoteStore.removeIfPresent(el2 + '.bak');
    }
    NoteStore.movedToEl5 = true;
  }

  private static replaceFile(path: string, text: string): boolean {
    let temp = path + '.tmp';
    let backup = path + '.bak';
    let moved = false;
    try {
      if (!NoteStore.writeNew(temp, text)) {
        NoteStore.removeIfPresent(temp);
        return false;
      }
      if (NoteStore.exists(path)) {
        fileIo.renameSync(path, backup);
        moved = true;
      }
      fileIo.renameSync(temp, path);
      if (moved) {
        NoteStore.removeIfPresent(backup);
      }
      return true;
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'save %{public}s', JSON.stringify(err));
      if (moved && !NoteStore.exists(path) && NoteStore.exists(backup)) {
        try {
          fileIo.renameSync(backup, path);
        } catch (restoreErr) {
          hilog.error(DOMAIN, TAG, 'restore %{public}s', JSON.stringify(restoreErr));
        }
      }
      NoteStore.removeIfPresent(temp);
      return false;
    }
  }

  private static writeNew(path: string, text: string): boolean {
    try {
      let file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, text);
        fileIo.fsyncSync(file.fd);
      } catch (writeErr) {
        NoteStore.closeQuiet(file);
        NoteStore.removeIfPresent(path);
        hilog.error(DOMAIN, TAG, 'write %{public}s', JSON.stringify(writeErr));
        return false;
      }
      if (!NoteStore.closeQuiet(file)) {
        NoteStore.removeIfPresent(path);
        return false;
      }
      return true;
    } catch (openErr) {
      NoteStore.removeIfPresent(path);
      hilog.error(DOMAIN, TAG, 'open %{public}s path %{public}s', JSON.stringify(openErr), path);
      return false;
    }
  }

  private static closeQuiet(file: fileIo.File): boolean {
    try {
      fileIo.closeSync(file);
      return true;
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'close %{public}s', JSON.stringify(err));
      return false;
    }
  }

  private static clearFiles(ctx: common.UIAbilityContext): boolean {
    let path = NoteStore.notePath(ctx);
    if (NoteStore.exists(path)) {
      try {
        fileIo.unlinkSync(path);
      } catch (err) {
        hilog.error(DOMAIN, TAG, 'clear %{public}s', JSON.stringify(err));
        return false;
      }
    }
    NoteStore.removeIfPresent(path + '.tmp');
    NoteStore.removeIfPresent(path + '.bak');
    return true;
  }

  private static removeIfPresent(path: string): void {
    if (!NoteStore.exists(path)) {
      return;
    }
    try {
      fileIo.unlinkSync(path);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'remove %{public}s', JSON.stringify(err));
    }
  }

  private static exists(path: string): boolean {
    try {
      return fileIo.accessSync(path);
    } catch (err) {
      return false;
    }
  }
}
