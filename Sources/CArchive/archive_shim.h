#ifndef PANEROOK_ARCHIVE_SHIM_H
#define PANEROOK_ARCHIVE_SHIM_H
#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>
#include <time.h>
/* The system SDK ships libarchive but omits its public headers. These are the
   stable libarchive 3 C ABI declarations used by PaneRook (archive.h and
   archive_entry.h at https://github.com/libarchive/libarchive). */
struct archive;
struct archive_entry;
struct archive *archive_read_new(void);
int archive_read_support_filter_none(struct archive *);
int archive_read_support_filter_gzip(struct archive *);
int archive_read_support_format_tar(struct archive *);
int archive_read_support_format_zip(struct archive *);
int archive_read_open_filename(struct archive *, const char *, size_t);
int archive_read_next_header(struct archive *, struct archive_entry **);
ssize_t archive_read_data(struct archive *, void *, size_t);
int archive_read_data_skip(struct archive *);
int archive_read_free(struct archive *);
int archive_format(struct archive *);
int archive_filter_code(struct archive *, int);
int archive_read_has_encrypted_entries(struct archive *);
const char *archive_error_string(struct archive *);
struct archive *archive_write_new(void);
int archive_write_set_format_zip(struct archive *);
int archive_write_set_format_pax_restricted(struct archive *);
int archive_write_add_filter_gzip(struct archive *);
int archive_write_open_fd(struct archive *, int);
int archive_write_header(struct archive *, struct archive_entry *);
ssize_t archive_write_data(struct archive *, const void *, size_t);
int archive_write_finish_entry(struct archive *);
int archive_write_close(struct archive *);
int archive_write_free(struct archive *);
struct archive_entry *archive_entry_new(void);
struct archive_entry *archive_entry_clone(struct archive_entry *);
void archive_entry_free(struct archive_entry *);
const char *archive_entry_pathname(struct archive_entry *);
unsigned int archive_entry_filetype(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
mode_t archive_entry_perm(struct archive_entry *);
time_t archive_entry_mtime(struct archive_entry *);
long archive_entry_mtime_nsec(struct archive_entry *);
const char *archive_entry_symlink(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);
void archive_entry_set_pathname(struct archive_entry *, const char *);
void archive_entry_set_filetype(struct archive_entry *, unsigned int);
void archive_entry_set_perm(struct archive_entry *, mode_t);
void archive_entry_set_size(struct archive_entry *, int64_t);
void archive_entry_set_mtime(struct archive_entry *, time_t, long);
#endif
