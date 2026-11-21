package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

const maxCatalogBytes = 4 << 20

type profileStore struct{ file, activeFile string }

func profileDPAPI(data []byte, seal bool) ([]byte, error) {
	if len(data) == 0 {
		return nil, errors.New("代理配置为空")
	}
	in := windows.DataBlob{Size: uint32(len(data)), Data: &data[0]}
	var out windows.DataBlob
	var err error
	if seal {
		err = windows.CryptProtectData(&in, nil, nil, 0, nil, windows.CRYPTPROTECT_UI_FORBIDDEN, &out)
	} else {
		err = windows.CryptUnprotectData(&in, nil, nil, 0, nil, windows.CRYPTPROTECT_UI_FORBIDDEN, &out)
	}
	if err != nil {
		return nil, errors.New("当前 Windows 帐户无法处理代理凭据")
	}
	defer windows.LocalFree(windows.Handle(unsafe.Pointer(out.Data)))
	buf := unsafe.Slice(out.Data, out.Size)
	defer clear(buf)
	return bytes.Clone(buf), nil
}

func readProfileFile(path string, limit int64) ([]byte, error) {
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return nil, err
	}
	h, err := windows.CreateFile(name, windows.GENERIC_READ, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE,
		nil, windows.OPEN_EXISTING, windows.FILE_ATTRIBUTE_NORMAL, 0)
	if err != nil {
		return nil, err
	}
	f := os.NewFile(uintptr(h), path)
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, limit+1))
	defer clear(data)
	if err != nil || int64(len(data)) > limit {
		return nil, errors.New("代理配置文件读取失败或超出大小限制")
	}
	return profileDPAPI(data, false)
}

func (s *profileStore) load() (*profileBook, error) {
	b := &profileBook{}
	raw, err := readProfileFile(s.file, maxCatalogBytes)
	if err == nil {
		defer clear(raw)
		if json.Unmarshal(raw, b) != nil || b.Version != 1 || b.Entries == nil {
			return nil, errors.New("代理配置列表格式无效，已保留原文件")
		}
		seen := profileBook{}
		for i := range b.Entries {
			p := &b.Entries[i]
			if name, err := validName(p.Name); err != nil || name != p.Name || p.ID == "" || seen.find(p.ID) != nil ||
				seen.nameTaken(name, "") || p.Values.normalize() != nil {
				return nil, errors.New("代理配置列表包含无效项，已保留原文件")
			}
			seen.Entries = append(seen.Entries, *p)
		}
	} else if os.IsNotExist(err) {
		b.Version = 1
		b.Entries = []namedProfile{}
	} else {
		return nil, errors.New("无法读取当前帐户的代理配置列表，已保留原文件")
	}
	active, err := readProfileFile(s.activeFile, 65536)
	if os.IsNotExist(err) {
		return b, nil
	}
	defer clear(active)
	var c clashProfile
	if err == nil && json.Unmarshal(bytes.TrimPrefix(active, []byte{0xef, 0xbb, 0xbf}), &c) == nil && c.supported() {
		if v, err := c.values(); err == nil {
			b.includeDeployed(v)
			return b, nil
		}
	}
	b.warning = "当前帐户无法读取已部署代理。已保存的命名配置仍可查看。"
	return b, nil
}

// Serialize read-modify-replace across different logon sessions of the same
// user. Temporary and final files both contain only CurrentUser DPAPI ciphertext.
func (s *profileStore) change(edit func(*profileBook) error) (*profileBook, error) {
	dir := filepath.Dir(s.file)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, errors.New("无法创建代理配置目录")
	}
	lock, err := os.OpenFile(s.file+".lock", os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, errors.New("无法打开代理配置锁")
	}
	defer lock.Close()
	handle := windows.Handle(lock.Fd())
	var overlap windows.Overlapped
	deadline := time.Now().Add(time.Second)
	for {
		err = windows.LockFileEx(handle, windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &overlap)
		if err == nil {
			break
		}
		if !errors.Is(err, windows.ERROR_LOCK_VIOLATION) || time.Now().After(deadline) {
			return nil, errors.New("代理列表正在使用，请重试")
		}
		time.Sleep(15 * time.Millisecond)
	}
	defer windows.UnlockFileEx(handle, 0, 1, 0, &overlap)
	b, err := s.load()
	if err != nil {
		return nil, err
	}
	if err = edit(b); err != nil {
		return nil, err
	}
	plain, err := json.Marshal(b)
	if err != nil {
		return nil, errors.New("代理列表序列化失败")
	}
	defer clear(plain)
	sealed, err := profileDPAPI(plain, true)
	if err != nil {
		return nil, err
	}
	defer clear(sealed)
	if len(sealed) > maxCatalogBytes {
		return nil, errors.New("代理列表超过 4 MiB，未写入")
	}
	tmp, err := os.CreateTemp(dir, ".profiles-*.dpapi")
	if err != nil {
		return nil, errors.New("无法创建代理列表临时文件")
	}
	defer os.Remove(tmp.Name())
	_, err = tmp.Write(sealed)
	if err == nil {
		err = tmp.Sync()
	}
	closeErr := tmp.Close()
	if err != nil || closeErr != nil {
		return nil, errors.New("代理列表保存失败，原配置仍在")
	}
	if err = os.Rename(tmp.Name(), s.file); err != nil {
		return nil, errors.New("代理列表替换失败，原配置仍在")
	}
	return b, nil
}

func (s *profileStore) resolve(id string, preserve bool) (proxyValues, error) {
	b, err := s.load()
	if err != nil {
		return proxyValues{}, err
	}
	if preserve && b.virtual && id != b.active && b.find(id) != nil {
		// Preserve the previous, otherwise unnamed deployment before a switch.
		b, err = s.change(func(*profileBook) error { return nil })
		if err != nil {
			return proxyValues{}, err
		}
	}
	if p := b.find(id); p != nil {
		return p.Values, nil
	}
	return proxyValues{}, errors.New("所选配置已变化，请刷新列表")
}
