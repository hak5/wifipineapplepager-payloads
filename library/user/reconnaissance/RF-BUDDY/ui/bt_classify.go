package main

import (
	"fmt"
	"strconv"
)

// bleClass is the identification of one device, derived from its adverts and
// the embedded SIG / OUI database. It is computed when an input changes, not
// on every render.
type bleClass struct {
	valid     bool
	brand     string // never empty once valid
	makerFull string
	typ       string // never empty once valid
	appear    string
	addrKind  string
	services  []string
}

// bleClassIn holds every input of the classifier.
type bleClassIn struct {
	addr     string
	random   bool
	company  int
	name     string
	hint     string
	mfrKind  string
	svcKind  string
	appearV  int
	services []int
}

func (e *bleEntry) classIn() bleClassIn {
	return bleClassIn{
		addr: e.addr, random: e.random, company: e.company, name: e.name, hint: e.hint,
		mfrKind: e.mfrKind, svcKind: e.svcKind, appearV: e.appearV,
		services: append([]int(nil), e.services...),
	}
}

// Address kinds.
const (
	addrPublic    = "PUBLIC"
	addrStatic    = "STATIC"
	addrPrivate   = "PRIVATE"    // resolvable private
	addrNonResolv = "NON-RESOLV" // non-resolvable private (and reserved 0b10)
)

// bleAddrKind classifies the address from its type and the top two bits of
// the first displayed byte. An unparsable random address is NON-RESOLV.
func bleAddrKind(addr string, random bool) string {
	if !random {
		return addrPublic
	}
	if len(addr) >= 2 {
		if b, err := strconv.ParseUint(addr[:2], 16, 8); err == nil {
			switch b >> 6 {
			case 3:
				return addrStatic
			case 1:
				return addrPrivate
			}
		}
	}
	return addrNonResolv
}

// memberBrandSkip lists service UUIDs registered to a company but used by many
// makers (Exposure Notification, Eddystone), so they say nothing about the maker.
func memberBrandSkip(uuid int) bool { return uuid == 0xFD6F || uuid == 0xFEAA }

// classifyBLE derives brand, kind and friendly names. With useDB=false it
// never touches the lazily loaded database (cheap provisional answer).
//
// Brand: company id > byte-swapped company id > member service UUID > name
// keyword > OUI (PUBLIC addresses only; random addresses carry no maker) > first word of the name >
// service hint > "ID XXXX" > UNKNOWN.
// Kind: manufacturer kind > name keyword kind (unless OTHER) > service kind >
// SIG appearance > OTHER.
func classifyBLE(in bleClassIn, useDB bool) bleClass {
	c := bleClass{valid: true, addrKind: bleAddrKind(in.addr, in.random)}
	brand, full, idBrand := "", "", false
	if in.company >= 0 {
		if useDB {
			if b, f, ok := CompanyBrand(in.company); ok {
				brand, full = b, f
			} else if sw := in.company&0xFF<<8 | in.company>>8; sw != in.company {
				if b, f, ok := CompanyBrand(sw); ok {
					brand, full = b, f
				}
			}
		} else if n, ok := companyNames[in.company]; ok {
			brand, full = n, n
		}
	}
	if brand == "" && useDB {
		for _, u := range in.services {
			if memberBrandSkip(u) {
				continue
			}
			if b, f, ok := MemberBrand(u); ok {
				brand, full = b, f
				break
			}
		}
	}
	nameBrand, nameKind := nameKeyword(in.name)
	if brand == "" {
		brand = nameBrand
	}
	if brand == "" && useDB && c.addrKind == addrPublic {
		if b, ok := OUIBrand(in.addr); ok {
			brand = b
		}
	}
	if brand == "" {
		if w := nameWord(in.name); w != "UNKNOWN" {
			brand = trimCells(w, 16)
		}
	}
	if brand == "" {
		brand = in.hint
	}
	if brand == "" && in.company >= 0 {
		brand, idBrand = fmt.Sprintf("ID %04X", in.company), true
	}
	if brand == "" {
		brand = "UNKNOWN"
	}
	c.brand = brand
	if full == "" && !idBrand && brand != "UNKNOWN" {
		full = brand
	}
	c.makerFull = full

	if in.appearV >= 0 {
		if useDB {
			c.appear, _ = AppearanceName(in.appearV)
		}
		if c.appear == "" {
			c.appear = AppearanceType(in.appearV)
		}
	}
	switch {
	case in.mfrKind != "":
		c.typ = in.mfrKind
	case nameKind != "" && nameKind != "OTHER":
		c.typ = nameKind
	case in.svcKind != "":
		c.typ = in.svcKind
	case c.appear != "":
		c.typ = c.appear
	default:
		c.typ = "OTHER"
	}
	if useDB {
		for _, u := range in.services {
			if len(c.services) >= 3 {
				break
			}
			if n, ok := ServiceName(u); ok {
				c.services = append(c.services, n)
			}
		}
	}
	return c
}

// warmBTDB loads the identification database ahead of the first advert. The
// first lookup parses ~40k OUI rows (slow on the Pager's MIPS core), so it is
// triggered from a background goroutine when Bluetooth starts; the decoder
// goroutine may block on the sync.Once, the render loop never does.
func warmBTDB() {
	CompanyBrand(0)
	MemberBrand(0)
	ServiceName(0)
	AppearanceName(0x40)
	OUIBrand("00:00:00")
}
