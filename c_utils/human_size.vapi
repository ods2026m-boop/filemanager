[CCode (cprefix = "", lower_case_cprefix = "", cheader_filename = "human_size.h")]
namespace HumanSize {
    [CCode (cname = "human_size")]
    public unowned string human_size(uint64 bytes);
}
