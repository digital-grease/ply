//! A lean JSON tree for the migrations of an older `.plyknit` (ADR 0002, ADR 0007, amendments of
//! 2026-11-18): the same values as a `serde_json::Value`, read, compared and decoded the same way,
//! with far less memory for small objects and no more for anything else.
//!
//! **Why.** A `serde_json::Value` object is a `BTreeMap`, and a map with one entry still takes a
//! whole node of eleven: about 630 bytes for an object such as `{"stitch":0}`. A crafted older file
//! at the restore's value limit (3 million values) decoded to some 900 MiB that way, and a real
//! shape (a chart's cells, a section's steps) to 500 to 800 MiB. Here an object is a sorted slice of
//! its entries, 40 bytes each (the key's box and the value), and a list a slice of its values, 24
//! bytes each (a `Value` takes 32). At the value limit (see `tests/older_decode_bound.rs`) that is
//! a fifth to a fifteenth of the tree's memory for a file of small objects, about two thirds for one
//! long list, and nine tenths for one object with a key for every value.
//!
//! **The same tree.** [`Json::parse`] reads a text exactly as `serde_json::from_str::<Value>` does:
//! the same parser walks every value the same way (so the same texts are refused with the same
//! errors), numbers are held as the same [`serde_json::Number`], and an object keeps one entry a key
//! (the last of a repeated key), sorted by key as a `BTreeMap` sorts them, so it iterates, compares
//! and decodes in the same order. While an object is read, its entries so far are compacted (sorted,
//! a repeated key's earlier values dropped) whenever they reach twice what the last compaction left,
//! so a key repeated millions of times is held about once, as a `BTreeMap` holds it.
//!
//! **The same decode.** A [`Json`] is a `serde::Deserializer` that mirrors `serde_json::Value`'s own
//! (owned) deserializer, method for method: every type reads from it what it reads from a `Value`,
//! with the same errors (an object as an enum must have one key; a struct variant must be an
//! object; a list read as a struct or tuple must have no values left over; and so on), keys included:
//! a key read as a number or as `true` or `false` is parsed as serde_json parses it. Lists and
//! objects give no size hint (a hint changes nothing read; see `SeqDeserializer`). Decoding consumes
//! the tree, so each value's own allocation is freed as it is read.

use serde::de::{
    self, Deserialize, DeserializeSeed, Deserializer, EnumAccess, Expected, IntoDeserializer,
    MapAccess, SeqAccess, Unexpected, VariantAccess, Visitor,
};
use serde::forward_to_deserialize_any;
use serde_json::{Error, Number, Value};
use std::fmt;

/// A JSON value, as a `serde_json::Value` holds it (see the module docs).
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Json {
    Null,
    Bool(bool),
    Number(Number),
    String(Box<str>),
    Array(Box<[Json]>),
    Object(Object),
}

/// A JSON object: one entry a key, sorted by key as a `BTreeMap<String, _>` sorts them.
#[derive(Debug, Clone, PartialEq, Default)]
pub(crate) struct Object(Box<[(Box<str>, Json)]>);

impl Json {
    /// Parse `text` as `serde_json::from_str::<serde_json::Value>` does: the same tree, the same
    /// errors.
    pub(crate) fn parse(text: &str) -> Result<Json, Error> {
        let mut de = serde_json::Deserializer::from_str(text);
        let value = Json::deserialize(&mut de)?;
        de.end()?;
        Ok(value)
    }

    /// The value of `key` when this is an object that has it (as `Value::get` with a text key).
    pub(crate) fn get(&self, key: &str) -> Option<&Json> {
        self.as_object().and_then(|o| o.get(key))
    }

    pub(crate) fn get_mut(&mut self, key: &str) -> Option<&mut Json> {
        self.as_object_mut().and_then(|o| o.get_mut(key))
    }

    pub(crate) fn as_object(&self) -> Option<&Object> {
        match self {
            Json::Object(o) => Some(o),
            _ => None,
        }
    }

    pub(crate) fn as_object_mut(&mut self) -> Option<&mut Object> {
        match self {
            Json::Object(o) => Some(o),
            _ => None,
        }
    }

    pub(crate) fn as_array(&self) -> Option<&[Json]> {
        match self {
            Json::Array(a) => Some(a),
            _ => None,
        }
    }

    pub(crate) fn as_array_mut(&mut self) -> Option<&mut Box<[Json]>> {
        match self {
            Json::Array(a) => Some(a),
            _ => None,
        }
    }

    /// The number as a `u64`, when it is a whole number that fits (as `Value::as_u64`).
    pub(crate) fn as_u64(&self) -> Option<u64> {
        match self {
            Json::Number(n) => n.as_u64(),
            _ => None,
        }
    }

    /// What this value is, for an error message (as `serde_json::Value` names it).
    fn unexpected(&self) -> Unexpected<'_> {
        match self {
            Json::Null => Unexpected::Unit,
            Json::Bool(b) => Unexpected::Bool(*b),
            Json::Number(n) => {
                if let Some(u) = n.as_u64() {
                    Unexpected::Unsigned(u)
                } else if let Some(i) = n.as_i64() {
                    Unexpected::Signed(i)
                } else {
                    Unexpected::Float(n.as_f64().unwrap_or(f64::NAN))
                }
            }
            Json::String(s) => Unexpected::Str(s),
            Json::Array(_) => Unexpected::Seq,
            Json::Object(_) => Unexpected::Map,
        }
    }

    fn invalid_type<E: de::Error>(&self, exp: &dyn Expected) -> E {
        de::Error::invalid_type(self.unexpected(), exp)
    }
}

impl Object {
    /// The object of `entries` in the order a text gave them: sorted by key, and a repeated key
    /// keeps its last value (as inserting them one by one into a `BTreeMap` does).
    fn from_entries(mut entries: Vec<(Box<str>, Json)>) -> Object {
        compact(&mut entries);
        Object(entries.into_boxed_slice())
    }

    fn find(&self, key: &str) -> Result<usize, usize> {
        self.0.binary_search_by(|(k, _)| (**k).cmp(key))
    }

    pub(crate) fn len(&self) -> usize {
        self.0.len()
    }

    pub(crate) fn contains_key(&self, key: &str) -> bool {
        self.find(key).is_ok()
    }

    pub(crate) fn get(&self, key: &str) -> Option<&Json> {
        self.find(key).ok().map(|i| &self.0[i].1)
    }

    pub(crate) fn get_mut(&mut self, key: &str) -> Option<&mut Json> {
        self.find(key).ok().map(|i| &mut self.0[i].1)
    }

    /// Set `key` to `value` (as `Map::insert`): the old value is replaced and returned, or the key
    /// is added in its sorted place. Adding grows the slice by exactly one entry (a `Vec` would
    /// double it, and then shrink it back: for an object of millions of keys, twice the memory).
    pub(crate) fn insert(&mut self, key: &str, value: Json) -> Option<Json> {
        match self.find(key) {
            Ok(i) => Some(std::mem::replace(&mut self.0[i].1, value)),
            Err(i) => {
                let mut entries = std::mem::take(&mut self.0).into_vec();
                entries.reserve_exact(1);
                entries.insert(i, (key.into(), value));
                self.0 = entries.into_boxed_slice();
                None
            }
        }
    }

    /// The value of `key`, the rest of the object dropped (as `Map::remove` on an object that is
    /// then dropped): nothing is moved or allocated, however many keys it has.
    pub(crate) fn into_value(self, key: &str) -> Option<Json> {
        let i = self.find(key).ok()?;
        Some(self.0.into_vec().swap_remove(i).1)
    }

    /// The entries in key order, values mutable (as `Map::iter_mut`).
    pub(crate) fn iter_mut(&mut self) -> impl Iterator<Item = (&str, &mut Json)> {
        self.0.iter_mut().map(|(k, v)| (&**k, v))
    }

    /// The keys in order (as `Map::keys`).
    pub(crate) fn keys(&self) -> impl Iterator<Item = &str> {
        self.0.iter().map(|(k, _)| &**k)
    }
}

impl From<Value> for Json {
    fn from(value: Value) -> Json {
        match value {
            Value::Null => Json::Null,
            Value::Bool(b) => Json::Bool(b),
            Value::Number(n) => Json::Number(n),
            Value::String(s) => Json::String(s.into_boxed_str()),
            Value::Array(a) => Json::Array(a.into_iter().map(Json::from).collect()),
            Value::Object(o) => Json::Object(Object(
                o.into_iter()
                    .map(|(k, v)| (k.into_boxed_str(), Json::from(v)))
                    .collect(),
            )),
        }
    }
}

#[cfg(test)]
impl From<Json> for Value {
    fn from(json: Json) -> Value {
        match json {
            Json::Null => Value::Null,
            Json::Bool(b) => Value::Bool(b),
            Json::Number(n) => Value::Number(n),
            Json::String(s) => Value::String(s.into_string()),
            Json::Array(a) => Value::Array(a.into_vec().into_iter().map(Value::from).collect()),
            Json::Object(o) => Value::Object(
                o.0.into_vec()
                    .into_iter()
                    .map(|(k, v)| (k.into_string(), Value::from(v)))
                    .collect(),
            ),
        }
    }
}

// --- reading a text: `serde_json::Value`'s own visitor, value for value ---------------------------

impl<'de> Deserialize<'de> for Json {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Json, D::Error> {
        d.deserialize_any(JsonVisitor)
    }
}

struct JsonVisitor;

impl<'de> Visitor<'de> for JsonVisitor {
    type Value = Json;
    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("any valid JSON value")
    }
    fn visit_bool<E>(self, v: bool) -> Result<Json, E> {
        Ok(Json::Bool(v))
    }
    fn visit_i64<E>(self, v: i64) -> Result<Json, E> {
        Ok(Json::Number(v.into()))
    }
    fn visit_i128<E: de::Error>(self, v: i128) -> Result<Json, E> {
        Number::deserialize(de::value::I128Deserializer::new(v)).map(Json::Number)
    }
    fn visit_u64<E>(self, v: u64) -> Result<Json, E> {
        Ok(Json::Number(v.into()))
    }
    fn visit_u128<E: de::Error>(self, v: u128) -> Result<Json, E> {
        Number::deserialize(de::value::U128Deserializer::new(v)).map(Json::Number)
    }
    fn visit_f64<E>(self, v: f64) -> Result<Json, E> {
        Ok(Number::from_f64(v).map_or(Json::Null, Json::Number))
    }
    fn visit_str<E>(self, v: &str) -> Result<Json, E> {
        Ok(Json::String(v.into()))
    }
    fn visit_string<E>(self, v: String) -> Result<Json, E> {
        Ok(Json::String(v.into_boxed_str()))
    }
    fn visit_none<E>(self) -> Result<Json, E> {
        Ok(Json::Null)
    }
    fn visit_some<D: Deserializer<'de>>(self, d: D) -> Result<Json, D::Error> {
        Json::deserialize(d)
    }
    fn visit_unit<E>(self) -> Result<Json, E> {
        Ok(Json::Null)
    }
    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Json, A::Error> {
        let mut values = Vec::new();
        while let Some(v) = seq.next_element()? {
            values.push(v);
        }
        Ok(Json::Array(values.into_boxed_slice()))
    }
    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Json, A::Error> {
        let mut entries = Vec::new();
        let mut compact_at = MIN_COMPACT;
        while let Some(entry) = map.next_entry::<Box<str>, Json>()? {
            entries.push(entry);
            if entries.len() >= compact_at {
                // A `BTreeMap` drops a repeated key's earlier value as the later one arrives;
                // compacting as the entries double does the same, a doubling late at most.
                compact(&mut entries);
                compact_at = (2 * entries.len()).max(MIN_COMPACT);
            }
        }
        Ok(Json::Object(Object::from_entries(entries)))
    }
}

/// The fewest entries an object being read gathers before they are compacted.
const MIN_COMPACT: usize = 64;

/// Sort `entries` by key and keep one a key, with the value of its last occurrence. The sort is
/// stable, so a repeated key's entries stay in the text's order (entries compacted before come
/// before every entry read after); of each run, the first is kept with the last one's value.
fn compact(entries: &mut Vec<(Box<str>, Json)>) {
    entries.sort_by(|a, b| a.0.cmp(&b.0));
    entries.dedup_by(|later, kept| {
        if later.0 == kept.0 {
            std::mem::swap(&mut later.1, &mut kept.1);
            true
        } else {
            false
        }
    });
}

// --- decoding from the tree: `serde_json::Value`'s owned deserializer, method for method ----------

/// A list read as a sequence: every value must be read (as `serde_json`'s `visit_array`).
fn visit_array<'de, V: Visitor<'de>>(array: Box<[Json]>, visitor: V) -> Result<V::Value, Error> {
    let len = array.len();
    let mut de = SeqDeserializer(array.into_vec().into_iter());
    let seq = visitor.visit_seq(&mut de)?;
    if de.0.len() == 0 {
        Ok(seq)
    } else {
        Err(de::Error::invalid_length(len, &"fewer elements in array"))
    }
}

/// An object read as a map: every entry must be read (as `Map`'s `deserialize_any`).
fn visit_object<'de, V: Visitor<'de>>(object: Object, visitor: V) -> Result<V::Value, Error> {
    let len = object.len();
    let mut de = MapDeserializer {
        iter: object.0.into_vec().into_iter(),
        value: None,
    };
    let map = visitor.visit_map(&mut de)?;
    if de.iter.len() == 0 {
        Ok(map)
    } else {
        Err(de::Error::invalid_length(len, &"fewer elements in map"))
    }
}

/// An object read as an enum: exactly one key, the variant (as `Map`'s `deserialize_enum`).
fn object_as_enum<'de, V: Visitor<'de>>(object: Object, visitor: V) -> Result<V::Value, Error> {
    let mut iter = object.0.into_vec().into_iter();
    let Some((variant, value)) = iter.next() else {
        return Err(de::Error::invalid_value(
            Unexpected::Map,
            &"map with a single key",
        ));
    };
    if iter.next().is_some() {
        return Err(de::Error::invalid_value(
            Unexpected::Map,
            &"map with a single key",
        ));
    }
    visitor.visit_enum(EnumDeserializer {
        variant,
        value: Some(value),
    })
}

macro_rules! deserialize_number {
    ($method:ident) => {
        fn $method<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value, Error> {
            match self {
                Json::Number(n) => n.deserialize_any(visitor),
                _ => Err(self.invalid_type(&visitor)),
            }
        }
    };
}

impl<'de> Deserializer<'de> for Json {
    type Error = Error;

    fn deserialize_any<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value, Error> {
        match self {
            Json::Null => visitor.visit_unit(),
            Json::Bool(v) => visitor.visit_bool(v),
            Json::Number(n) => n.deserialize_any(visitor),
            Json::String(v) => visitor.visit_string(v.into_string()),
            Json::Array(v) => visit_array(v, visitor),
            Json::Object(v) => visit_object(v, visitor),
        }
    }

    deserialize_number!(deserialize_i8);
    deserialize_number!(deserialize_i16);
    deserialize_number!(deserialize_i32);
    deserialize_number!(deserialize_i64);
    deserialize_number!(deserialize_i128);
    deserialize_number!(deserialize_u8);
    deserialize_number!(deserialize_u16);
    deserialize_number!(deserialize_u32);
    deserialize_number!(deserialize_u64);
    deserialize_number!(deserialize_u128);
    deserialize_number!(deserialize_f32);
    deserialize_number!(deserialize_f64);

    fn deserialize_option<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value, Error> {
        match self {
            Json::Null => visitor.visit_none(),
            _ => visitor.visit_some(self),
        }
    }

    fn deserialize_enum<V: Visitor<'de>>(
        self,
        _name: &'static str,
        _variants: &'static [&'static str],
        visitor: V,
    ) -> Result<V::Value, Error> {
        match self {
            Json::Object(v) => object_as_enum(v, visitor),
            Json::String(variant) => visitor.visit_enum(EnumDeserializer {
                variant,
                value: None,
            }),
            other => Err(de::Error::invalid_type(
                other.unexpected(),
                &"string or map",
            )),
        }
    }

    fn deserialize_newtype_struct<V: Visitor<'de>>(
        self,
        _name: &'static str,
        visitor: V,
    ) -> Result<V::Value, Error> {
        visitor.visit_newtype_struct(self)
    }

    fn deserialize_bool<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value, Error> {
        match self {
            Json::Bool(v) => visitor.visit_bool(v),
            _ => Err(self.invalid_type(&visitor)),
        }
    }

    fn deserialize_char<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value, Error> {
        self.deserialize_string(visitor)
    }

    fn deserialize_str<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value, Error> {
        self.deserialize_string(visitor)
    }

    fn deserialize_string<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value, Error> {
        match self {
            Json::String(v) => visitor.visit_string(v.into_string()),
            _ => Err(self.invalid_type(&visitor)),
        }
    }

    fn deserialize_bytes<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value, Error> {
        self.deserialize_byte_buf(visitor)
    }

    fn deserialize_byte_buf<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value, Error> {
        match self {
            Json::String(v) => visitor.visit_string(v.into_string()),
            Json::Array(v) => visit_array(v, visitor),
            _ => Err(self.invalid_type(&visitor)),
        }
    }

    fn deserialize_unit<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value, Error> {
        match self {
            Json::Null => visitor.visit_unit(),
            _ => Err(self.invalid_type(&visitor)),
        }
    }

    fn deserialize_unit_struct<V: Visitor<'de>>(
        self,
        _name: &'static str,
        visitor: V,
    ) -> Result<V::Value, Error> {
        self.deserialize_unit(visitor)
    }

    fn deserialize_seq<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value, Error> {
        match self {
            Json::Array(v) => visit_array(v, visitor),
            _ => Err(self.invalid_type(&visitor)),
        }
    }

    fn deserialize_tuple<V: Visitor<'de>>(
        self,
        _len: usize,
        visitor: V,
    ) -> Result<V::Value, Error> {
        self.deserialize_seq(visitor)
    }

    fn deserialize_tuple_struct<V: Visitor<'de>>(
        self,
        _name: &'static str,
        _len: usize,
        visitor: V,
    ) -> Result<V::Value, Error> {
        self.deserialize_seq(visitor)
    }

    fn deserialize_map<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value, Error> {
        match self {
            Json::Object(v) => visit_object(v, visitor),
            _ => Err(self.invalid_type(&visitor)),
        }
    }

    fn deserialize_struct<V: Visitor<'de>>(
        self,
        _name: &'static str,
        _fields: &'static [&'static str],
        visitor: V,
    ) -> Result<V::Value, Error> {
        match self {
            Json::Array(v) => visit_array(v, visitor),
            Json::Object(v) => visit_object(v, visitor),
            _ => Err(self.invalid_type(&visitor)),
        }
    }

    fn deserialize_identifier<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value, Error> {
        self.deserialize_string(visitor)
    }

    fn deserialize_ignored_any<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value, Error> {
        drop(self);
        visitor.visit_unit()
    }
}

struct EnumDeserializer {
    variant: Box<str>,
    value: Option<Json>,
}

impl<'de> EnumAccess<'de> for EnumDeserializer {
    type Error = Error;
    type Variant = VariantDeserializer;

    fn variant_seed<V: DeserializeSeed<'de>>(
        self,
        seed: V,
    ) -> Result<(V::Value, VariantDeserializer), Error> {
        let variant: de::value::StringDeserializer<Error> =
            self.variant.into_string().into_deserializer();
        let rest = VariantDeserializer { value: self.value };
        seed.deserialize(variant).map(|v| (v, rest))
    }
}

struct VariantDeserializer {
    value: Option<Json>,
}

impl<'de> VariantAccess<'de> for VariantDeserializer {
    type Error = Error;

    fn unit_variant(self) -> Result<(), Error> {
        match self.value {
            Some(value) => Deserialize::deserialize(value),
            None => Ok(()),
        }
    }

    fn newtype_variant_seed<T: DeserializeSeed<'de>>(self, seed: T) -> Result<T::Value, Error> {
        match self.value {
            Some(value) => seed.deserialize(value),
            None => Err(de::Error::invalid_type(
                Unexpected::UnitVariant,
                &"newtype variant",
            )),
        }
    }

    fn tuple_variant<V: Visitor<'de>>(self, _len: usize, visitor: V) -> Result<V::Value, Error> {
        match self.value {
            Some(Json::Array(v)) => {
                if v.is_empty() {
                    visitor.visit_unit()
                } else {
                    visit_array(v, visitor)
                }
            }
            Some(other) => Err(de::Error::invalid_type(
                other.unexpected(),
                &"tuple variant",
            )),
            None => Err(de::Error::invalid_type(
                Unexpected::UnitVariant,
                &"tuple variant",
            )),
        }
    }

    fn struct_variant<V: Visitor<'de>>(
        self,
        _fields: &'static [&'static str],
        visitor: V,
    ) -> Result<V::Value, Error> {
        match self.value {
            Some(Json::Object(v)) => visit_object(v, visitor),
            Some(other) => Err(de::Error::invalid_type(
                other.unexpected(),
                &"struct variant",
            )),
            None => Err(de::Error::invalid_type(
                Unexpected::UnitVariant,
                &"struct variant",
            )),
        }
    }
}

struct SeqDeserializer(std::vec::IntoIter<Json>);

impl<'de> SeqAccess<'de> for SeqDeserializer {
    type Error = Error;

    fn next_element_seed<T: DeserializeSeed<'de>>(
        &mut self,
        seed: T,
    ) -> Result<Option<T::Value>, Error> {
        match self.0.next() {
            Some(value) => seed.deserialize(value).map(Some),
            None => Ok(None),
        }
    }

    // No size hint (`serde_json`'s gives the exact length): a hint changes no value read, only
    // how a list is first allocated, and serde allocates at most 1 MiB from one and then doubles,
    // which for a list of millions of values ends further past its length than doubling from
    // nothing (measured: 260 MiB against 213 MiB for three million empty texts in one list).
}

struct MapDeserializer {
    iter: std::vec::IntoIter<(Box<str>, Json)>,
    value: Option<Json>,
}

impl<'de> MapAccess<'de> for MapDeserializer {
    type Error = Error;

    fn next_key_seed<T: DeserializeSeed<'de>>(
        &mut self,
        seed: T,
    ) -> Result<Option<T::Value>, Error> {
        match self.iter.next() {
            Some((key, value)) => {
                self.value = Some(value);
                seed.deserialize(KeyDeserializer(key.into_string()))
                    .map(Some)
            }
            None => Ok(None),
        }
    }

    fn next_value_seed<T: DeserializeSeed<'de>>(&mut self, seed: T) -> Result<T::Value, Error> {
        match self.value.take() {
            Some(value) => seed.deserialize(value),
            None => Err(de::Error::custom("value is missing")),
        }
    }

    // No size hint, as for a list.
}

/// An object's key (as `serde_json`'s owned map key deserializer reads one): text, or a number or
/// `true` or `false` parsed from the text when the type asks for one.
struct KeyDeserializer(String);

/// serde_json's refusal of a key that is not a number when a number is asked for: its sentence,
/// with no place in the text (serde_json gives it none).
fn expected_numeric_key() -> Error {
    de::Error::custom("invalid value: expected key to be a number in quotes")
}

/// A key read as a number, as serde_json reads one: it must start like a number and hold nothing
/// after it, not even a space. A reader of bytes (`from_reader`) is used because it lends nothing
/// to the visitor, which may outlive the key.
macro_rules! deserialize_numeric_key {
    ($method:ident) => {
        fn $method<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value, Error> {
            if !matches!(self.0.as_bytes().first(), Some(b'0'..=b'9' | b'-')) {
                return Err(expected_numeric_key());
            }
            let mut de = serde_json::Deserializer::from_reader(self.0.as_bytes());
            let number = (&mut de).$method(visitor)?;
            // `end` passes trailing whitespace, which serde_json does not allow after a key's number.
            if self.0.ends_with([' ', '\t', '\n', '\r']) || de.end().is_err() {
                return Err(expected_numeric_key());
            }
            Ok(number)
        }
    };
}

impl<'de> Deserializer<'de> for KeyDeserializer {
    type Error = Error;

    fn deserialize_any<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value, Error> {
        visitor.visit_string(self.0)
    }

    deserialize_numeric_key!(deserialize_i8);
    deserialize_numeric_key!(deserialize_i16);
    deserialize_numeric_key!(deserialize_i32);
    deserialize_numeric_key!(deserialize_i64);
    deserialize_numeric_key!(deserialize_i128);
    deserialize_numeric_key!(deserialize_u8);
    deserialize_numeric_key!(deserialize_u16);
    deserialize_numeric_key!(deserialize_u32);
    deserialize_numeric_key!(deserialize_u64);
    deserialize_numeric_key!(deserialize_u128);
    deserialize_numeric_key!(deserialize_f32);
    deserialize_numeric_key!(deserialize_f64);

    fn deserialize_bool<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value, Error> {
        match self.0.as_str() {
            "true" => visitor.visit_bool(true),
            "false" => visitor.visit_bool(false),
            other => Err(de::Error::invalid_type(Unexpected::Str(other), &visitor)),
        }
    }

    fn deserialize_option<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value, Error> {
        // Map keys cannot be null.
        visitor.visit_some(self)
    }

    fn deserialize_newtype_struct<V: Visitor<'de>>(
        self,
        _name: &'static str,
        visitor: V,
    ) -> Result<V::Value, Error> {
        visitor.visit_newtype_struct(self)
    }

    fn deserialize_enum<V: Visitor<'de>>(
        self,
        name: &'static str,
        variants: &'static [&'static str],
        visitor: V,
    ) -> Result<V::Value, Error> {
        let key: de::value::StringDeserializer<Error> = self.0.into_deserializer();
        key.deserialize_enum(name, variants, visitor)
    }

    forward_to_deserialize_any! {
        char str string bytes byte_buf unit unit_struct seq tuple tuple_struct map struct
        identifier ignored_any
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;
    use serde::Deserialize;

    #[test]
    fn a_json_value_takes_no_more_room_than_a_list_slot() {
        assert!(std::mem::size_of::<Json>() <= 24);
        // An object's entry: the key's box (16 bytes) and the value.
        assert!(std::mem::size_of::<(Box<str>, Json)>() <= 40);
        assert!(std::mem::size_of::<Json>() < std::mem::size_of::<Value>());
    }

    /// The tree's objects are sorted, as a `serde_json::Value`'s are only while serde_json's
    /// `preserve_order` feature is off (it is, in every build of the app). If this fails, a crate
    /// turned it on: a `Value` then keeps keys in the text's order, and this tree no longer matches.
    #[test]
    fn a_tree_object_is_sorted_as_a_value_object_is() {
        let v: Value = serde_json::from_str(r#"{"b":1,"a":2,"c":3}"#).unwrap();
        let keys: Vec<&String> = v.as_object().unwrap().keys().collect();
        assert_eq!(keys, ["a", "b", "c"]);
    }

    fn parse_both(text: &str) -> (Result<Value, String>, Result<Value, String>) {
        (
            Json::parse(text)
                .map(Value::from)
                .map_err(|e| e.to_string()),
            serde_json::from_str::<Value>(text).map_err(|e| e.to_string()),
        )
    }

    #[test]
    fn a_text_parses_to_the_tree_a_value_parses_to() {
        let deep = |n: usize| format!("{}{}", "[".repeat(n), "]".repeat(n));
        for text in [
            r#"{"b":[1,-2,3.5,-0,-0.0,1e20,18446744073709551615,-9223372036854775808],"a":{}}"#
                .to_string(),
            r#"{"k":1,"k":[2],"j":null,"k":{"x":true},"j":false}"#.into(),
            r#"{"\u00e9":"\ud83d\ude00","e\u0301":"\n\t\"","":""}"#.into(),
            r#"[{"a":1,"a":2},{"a":3},{}]"#.into(),
            r#"18446744073709551616"#.into(),
            r#"1e308"#.into(),
            "  null ".into(),
            deep(127),
            // Refused alike, with the same message.
            deep(128),
            format!(r#"{{"a":{}}}"#, deep(127)),
            r#"1e400"#.into(),
            r#"[-1e400]"#.into(),
            r#"{"a":"\ud83d"}"#.into(),
            r#"{"a":1,}"#.into(),
            r#"[1 2]"#.into(),
            "{} {}".into(),
            "".into(),
        ] {
            let (tree, value) = parse_both(&text);
            assert_eq!(tree, value, "{text:.80}");
        }
    }

    /// Types of every shape serde has, read from a lean tree and from a `serde_json::Value`.
    #[derive(Debug, PartialEq, Deserialize)]
    enum Shapes {
        Unit,
        Newtype(u8),
        Tuple(u8, String),
        Struct { a: Option<i32>, b: Vec<bool> },
        Empty {},
    }

    #[derive(Debug, PartialEq, Deserialize)]
    struct Fields {
        n: u16,
        f: f32,
        g: f64,
        i: i64,
        o: Option<String>,
        s: Shapes,
        t: (u8, char),
        u: (),
        w: Wrapper,
        #[serde(default)]
        d: Vec<Shapes>,
    }

    #[derive(Debug, PartialEq, Deserialize)]
    struct Wrapper(u32);

    #[derive(Debug, PartialEq, Deserialize)]
    struct Unit;

    /// `T` read both ways: the same value, or the same error.
    fn decoded_alike<T: for<'de> Deserialize<'de> + PartialEq + std::fmt::Debug>(v: &Value) {
        let from_tree = T::deserialize(Json::from(v.clone())).map_err(|e| e.to_string());
        let from_value = serde_json::from_value::<T>(v.clone()).map_err(|e| e.to_string());
        assert_eq!(from_tree, from_value, "{v}");
    }

    /// An object's keys read as `T` (its values skipped): how a map with keys of that type reads
    /// them, for key types a `BTreeMap` cannot hold (floats).
    #[derive(Debug, PartialEq)]
    struct KeysAs<T>(Vec<T>);

    impl<'de, T: Deserialize<'de>> Deserialize<'de> for KeysAs<T> {
        fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
            struct V<T>(std::marker::PhantomData<T>);
            impl<'de, T: Deserialize<'de>> Visitor<'de> for V<T> {
                type Value = KeysAs<T>;
                fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                    f.write_str("a map")
                }
                fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<KeysAs<T>, A::Error> {
                    let mut keys = Vec::new();
                    while let Some(k) = map.next_key()? {
                        map.next_value::<serde::de::IgnoredAny>()?;
                        keys.push(k);
                    }
                    Ok(KeysAs(keys))
                }
            }
            d.deserialize_map(V(std::marker::PhantomData))
        }
    }

    fn decoded_alike_as_all(v: &Value) {
        decoded_alike::<Fields>(v);
        decoded_alike::<std::collections::BTreeMap<u32, String>>(v);
        decoded_alike::<std::collections::BTreeMap<bool, serde::de::IgnoredAny>>(v);
        decoded_alike::<KeysAs<u8>>(v);
        decoded_alike::<KeysAs<i64>>(v);
        decoded_alike::<KeysAs<i128>>(v);
        decoded_alike::<KeysAs<u128>>(v);
        decoded_alike::<KeysAs<f32>>(v);
        decoded_alike::<KeysAs<f64>>(v);
        decoded_alike::<KeysAs<char>>(v);
        decoded_alike::<KeysAs<String>>(v);
        decoded_alike::<KeysAs<Option<u16>>>(v);
        decoded_alike::<KeysAs<Shapes>>(v);
        decoded_alike::<KeysAs<Wrapper>>(v);
        decoded_alike::<Shapes>(v);
        decoded_alike::<Vec<Shapes>>(v);
        decoded_alike::<Option<Wrapper>>(v);
        decoded_alike::<Unit>(v);
        decoded_alike::<(u8, Option<f32>)>(v);
        decoded_alike::<String>(v);
        decoded_alike::<u64>(v);
        decoded_alike::<i8>(v);
        decoded_alike::<bool>(v);
        decoded_alike::<char>(v);
        decoded_alike::<serde::de::IgnoredAny>(v);
    }

    #[test]
    fn every_shape_decodes_from_the_tree_as_from_a_value() {
        let full = serde_json::json!({
            "n": 7, "f": 1.0000000596046448, "g": -0.0, "i": -3, "o": "x",
            "s": {"Struct": {"a": 1, "b": [true]}}, "t": [1, "c"], "u": null, "w": 9,
            "d": ["Unit", {"Newtype": 3}, {"Tuple": [1, "x"]}, {"Empty": {}}],
        });
        let mut cases = vec![full.clone()];
        for (key, bad) in [
            ("n", serde_json::json!(70000)),
            ("n", serde_json::json!(-1)),
            ("n", serde_json::json!(1.5)),
            ("f", serde_json::json!(1e39)),
            ("f", serde_json::json!("1")),
            ("o", serde_json::json!(1)),
            ("s", serde_json::json!({"Unit": null})),
            ("s", serde_json::json!({"Unit": 1})),
            ("s", serde_json::json!({"Newtype": null})),
            ("s", serde_json::json!("Newtype")),
            ("s", serde_json::json!({"Tuple": []})),
            ("s", serde_json::json!({"Tuple": [1]})),
            ("s", serde_json::json!({"Tuple": [1, "a", 2]})),
            ("s", serde_json::json!({"Struct": [1, []]})),
            ("s", serde_json::json!({"Struct": {"a": null}})),
            ("s", serde_json::json!({"Empty": []})),
            ("s", serde_json::json!({"Unit": null, "Empty": {}})),
            ("s", serde_json::json!({})),
            ("s", serde_json::json!({"Other": 1})),
            ("s", serde_json::json!(["Unit"])),
            ("t", serde_json::json!([1, "cc"])),
            ("t", serde_json::json!([1])),
            ("t", serde_json::json!({"0": 1})),
            ("u", serde_json::json!([])),
            ("w", serde_json::json!([9])),
            ("w", serde_json::json!(null)),
            ("d", serde_json::json!({"Unit": null})),
        ] {
            let mut case = full.clone();
            case[key] = bad;
            cases.push(case);
        }
        let mut short = full.clone();
        short.as_object_mut().unwrap().remove("n");
        cases.push(short);
        let mut extra = full.clone();
        extra["zzz"] = serde_json::json!({"deep": [1, {"x": null}]});
        cases.push(extra);
        cases.push(serde_json::json!([
            7,
            1.0,
            2.0,
            3,
            null,
            "Unit",
            [1, "c"],
            null,
            9
        ]));
        cases.push(serde_json::json!([
            7,
            1.0,
            2.0,
            3,
            null,
            "Unit",
            [1, "c"],
            null,
            9,
            [],
            1
        ]));
        cases.push(serde_json::json!([1, null]));
        cases.push(serde_json::json!([1, 2.5, 3]));
        for case in &cases {
            decoded_alike_as_all(case);
        }
    }

    /// Keys read as numbers and as `true` or `false` are parsed as serde_json parses them, and
    /// refused alike (a key that does not start like a number, anything after the number).
    #[test]
    fn a_key_is_read_as_a_number_or_a_truth_value_as_from_a_value() {
        let keys = [
            "0",
            "1",
            "-1",
            "01",
            "-0",
            "300",
            "65536",
            "-129",
            "1.5",
            "1e3",
            "-2.5e-3",
            "1e400",
            "18446744073709551615",
            "18446744073709551616",
            "-9223372036854775809",
            "170141183460469231731687303715884105727",
            " 1",
            "1 ",
            "1\n",
            "\t1",
            "+1",
            "",
            "-",
            "1x",
            "1,2",
            "abc",
            "true",
            "false",
            "True",
            "null",
            "a",
            "Unit",
            "Newtype",
        ];
        for key in keys {
            let v = serde_json::json!({ key: 1 });
            decoded_alike_as_all(&v);
            let two = serde_json::json!({ key: 1, "7": 2 });
            decoded_alike_as_all(&two);
        }
        // The one the review found: a map with number keys.
        let v = serde_json::json!({"1": "x", "20": "y"});
        let map: std::collections::BTreeMap<u32, String> =
            Deserialize::deserialize(Json::from(v.clone())).unwrap();
        assert_eq!(map, serde_json::from_value(v).unwrap());
    }

    /// An object with a key repeated past the compaction threshold, many times and among other
    /// keys, is the tree a `Value` keeps: one entry a key, its last value.
    #[test]
    fn repeated_keys_past_the_compaction_threshold_keep_their_last_value() {
        let mut seed = 0x9e37_79b9_7f4a_7c15u64;
        let mut next = move || {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            seed
        };
        for (entries, distinct) in [
            (10_000, 1),
            (10_000, 3),
            (10_000, 100),
            (5_000, 4_000),
            (MIN_COMPACT, 1),
            (MIN_COMPACT + 1, 2),
            (2 * MIN_COMPACT, MIN_COMPACT),
            (3_000, 3_000),
        ] {
            let body: Vec<String> = (0..entries)
                .map(|i| format!(r#""k{}":{i}"#, next() % distinct as u64))
                .collect();
            let text = format!("{{{}}}", body.join(","));
            let (tree, value) = parse_both(&text);
            assert_eq!(tree, value, "{entries} entries of {distinct} keys");
            assert_eq!(
                Json::parse(&text).unwrap().as_object().unwrap().len(),
                value.unwrap().as_object().unwrap().len()
            );
        }
    }

    #[test]
    fn an_object_inserts_in_order_and_gives_up_a_value() {
        let mut o = match Json::parse(r#"{"b":1,"d":2}"#).unwrap() {
            Json::Object(o) => o,
            _ => unreachable!(),
        };
        assert_eq!(o.insert("c", Json::Null), None);
        assert_eq!(o.insert("a", Json::Bool(true)), None);
        assert_eq!(o.insert("d", Json::Null), Some(Json::Number(2.into())));
        assert_eq!(o.keys().collect::<Vec<_>>(), ["a", "b", "c", "d"]);
        assert_eq!(o.0.len(), 4);
        assert_eq!(o.clone().into_value("b"), Some(Json::Number(1.into())));
        assert_eq!(o.into_value("e"), None);
    }

    fn arb_value() -> impl Strategy<Value = Value> {
        let names = prop::sample::select(vec![
            "n", "f", "g", "i", "o", "s", "t", "u", "w", "d", "a", "b", "Unit", "Newtype", "Tuple",
            "Struct", "Empty", "0", "", "1", "-1", "300", "1.5", "1e3", " 1", "1 ", "true",
            "false", "x",
        ]);
        let leaf = prop_oneof![
            Just(Value::Null),
            any::<bool>().prop_map(Value::from),
            (0u64..300).prop_map(Value::from),
            any::<i64>().prop_map(Value::from),
            any::<u64>().prop_map(Value::from),
            any::<f64>().prop_map(Value::from),
            names.clone().prop_map(Value::from),
            ".{0,3}".prop_map(Value::from),
        ];
        leaf.prop_recursive(4, 32, 6, move |inner| {
            prop_oneof![
                prop::collection::vec(inner.clone(), 0..6).prop_map(Value::from),
                prop::collection::btree_map(names.clone(), inner, 0..6).prop_map(
                    |m| Value::Object(m.into_iter().map(|(k, v)| (k.into(), v)).collect())
                ),
            ]
        })
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(2048))]

        /// Any JSON text parses to the same tree, and any value decodes to the same result, as a
        /// `serde_json::Value`, for types of every shape serde has.
        #[test]
        fn any_value_parses_and_decodes_as_a_value_does(v in arb_value()) {
            let text = v.to_string();
            let (tree, value) = parse_both(&text);
            prop_assert_eq!(tree, value);
            decoded_alike_as_all(&v);
        }
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(256))]

        /// An object of up to 400 entries of a few keys, so the entries are compacted while it is
        /// read, parses to the tree a `Value` keeps.
        #[test]
        fn an_object_of_repeated_keys_parses_as_a_value_does(
            entries in prop::collection::vec(
                (
                    prop::sample::select(vec!["", "a", "b", "c", "ab", "ba", "d"]),
                    prop_oneof![
                        Just(Value::Null),
                        any::<i64>().prop_map(Value::from),
                        any::<u8>().prop_map(|n| serde_json::json!({ "n": n, "l": [n] })),
                    ],
                ),
                0..400,
            ),
        ) {
            let body: Vec<String> = entries
                .iter()
                .map(|(k, v)| format!("{}:{v}", serde_json::to_string(k).unwrap()))
                .collect();
            let text = format!("{{{}}}", body.join(","));
            let (tree, value) = parse_both(&text);
            prop_assert_eq!(tree, value);
        }
    }
}
